-- Peak — Phase 4-4a: text channels inside a community.
--
-- A community's feed is split into named channels ("general", "announcements",
-- "showcase", …). Every community has a "general" channel; admins add more.
-- A channel can be restricted so only moderators post in it (announcements).

create type channel_post_policy as enum ('members', 'moderators');

create table community_channel (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references community (id) on delete cascade,
  slug         citext not null check (slug ~ '^[a-z0-9][a-z0-9_-]{1,30}$'),
  name         text not null check (char_length(name) between 1 and 60),
  description  text not null default '' check (char_length(description) <= 280),
  position     int not null default 0,
  post_policy  channel_post_policy not null default 'members',
  created_at   timestamptz not null default now(),
  unique (community_id, slug)
);
create index community_channel_by_community
  on community_channel (community_id, position);

alter table community_channel enable row level security;
create policy community_channel_select on community_channel for select using (
  exists (select 1 from community c
          where c.id = community_id and can_view_community(c, auth.uid()))
);
-- writes via the RPCs below only

alter table post add column channel_id uuid
  references community_channel (id) on delete set null;
create index post_channel_created
  on post (channel_id, created_at desc)
  where deleted_at is null and channel_id is not null and reply_to is null;

-- ── backfill: a "general" channel per existing community; existing posts
--    move into it ────────────────────────────────────────────────────────
insert into community_channel (community_id, slug, name, position)
select id, 'general', 'General', 0 from community;

update post p
set channel_id = ch.id
from community_channel ch
where p.community_id is not null
  and ch.community_id = p.community_id
  and ch.slug = 'general';

-- ── a community post with no channel lands in "general"; a reply inherits
--    its parent's channel ────────────────────────────────────────────────
create or replace function post_default_channel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.community_id is not null and new.channel_id is null then
    if new.reply_to is not null then
      select channel_id into new.channel_id from post where id = new.reply_to;
    end if;
    if new.channel_id is null then
      select id into new.channel_id from community_channel
      where community_id = new.community_id and slug = 'general';
    end if;
  end if;
  return new;
end;
$$;

create trigger post_default_channel before insert on post
  for each row execute function post_default_channel();

-- ── helper: can `viewer` post in this channel? ─────────────────────────
create or replace function can_post_in_channel(p_channel uuid, viewer uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from community_channel ch
    where ch.id = p_channel
      and is_community_member(ch.community_id, viewer)
      and (ch.post_policy = 'members'
           or community_can_moderate(ch.community_id, viewer))
  );
$$;

-- posting into a community requires active membership; a community post must
-- name a channel of that community the author is allowed to post in.
drop policy post_insert on post;
create policy post_insert on post for insert with check (
  author_id = auth.uid()
  and exists (select 1 from persona pe
              where pe.id = persona_id and pe.account_id = auth.uid())
  and (
    community_id is null
    or (
      is_community_member(community_id, auth.uid())
      and channel_id is not null
      and exists (select 1 from community_channel ch
                  where ch.id = channel_id and ch.community_id = post.community_id)
      and (
        reply_to is not null                    -- replies inherit the channel
        or can_post_in_channel(channel_id, auth.uid())
      )
    )
  )
);

-- ── create_community also seeds the general channel ────────────────────
create or replace function create_community(
  p_slug text,
  p_name text,
  p_description text default '',
  p_topics text[] default '{}',
  p_join_policy community_join_policy default 'open',
  p_nsfw boolean default false
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;

  insert into community (slug, name, description, topics, join_policy, is_nsfw, created_by)
  values (lower(btrim(p_slug)), btrim(p_name), coalesce(btrim(p_description), ''),
          coalesce(p_topics, '{}'), p_join_policy, p_nsfw, v_me)
  returning id into v_id;

  insert into community_member (community_id, member_id, role, state)
  values (v_id, v_me, 'admin', 'active');

  insert into community_channel (community_id, slug, name, position)
  values (v_id, 'general', 'General', 0);

  return v_id;
end;
$$;

-- ── channel RPCs ──────────────────────────────────────────────────────
create or replace function community_channels(p_community_id uuid)
returns table (
  id uuid, slug citext, name text, description text,
  ord int, post_policy channel_post_policy, post_count bigint
)
language sql stable security definer set search_path = public as $$
  select
    ch.id, ch.slug, ch.name, ch.description, ch.position, ch.post_policy,
    (select count(*) from post p
     where p.channel_id = ch.id and p.deleted_at is null and p.reply_to is null)
  from community_channel ch
  join community c on c.id = ch.community_id
  where ch.community_id = p_community_id and can_view_community(c, auth.uid())
  order by ch.position, ch.created_at;
$$;

create or replace function create_channel(
  p_community_id uuid, p_slug text, p_name text,
  p_description text default '', p_mods_only boolean default false
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_pos int;
begin
  if community_role_of(p_community_id, auth.uid()) <> 'admin' then
    raise exception 'only an admin can add channels';
  end if;
  select coalesce(max(position), -1) + 1 into v_pos
  from community_channel where community_id = p_community_id;
  insert into community_channel
    (community_id, slug, name, description, position, post_policy)
  values (
    p_community_id, lower(btrim(p_slug)), btrim(p_name),
    coalesce(btrim(p_description), ''), v_pos,
    (case when p_mods_only then 'moderators' else 'members' end)::channel_post_policy
  )
  returning id into v_id;
  perform _mod_log(p_community_id, 'edit_settings');
  return v_id;
end;
$$;

create or replace function update_channel(
  p_channel_id uuid, p_name text, p_description text, p_mods_only boolean
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from community_channel where id = p_channel_id;
  if v_community is null then raise exception 'no such channel'; end if;
  if community_role_of(v_community, auth.uid()) <> 'admin' then
    raise exception 'only an admin can edit channels';
  end if;
  update community_channel set
    name = btrim(p_name),
    description = coalesce(btrim(p_description), ''),
    post_policy = (case when p_mods_only then 'moderators' else 'members' end)::channel_post_policy
  where id = p_channel_id;
  perform _mod_log(v_community, 'edit_settings');
end;
$$;

-- delete a channel; its posts fall back to the general channel (never orphaned)
create or replace function delete_channel(p_channel_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid; v_slug citext; v_general uuid;
begin
  select community_id, slug into v_community, v_slug
  from community_channel where id = p_channel_id;
  if v_community is null then raise exception 'no such channel'; end if;
  if community_role_of(v_community, auth.uid()) <> 'admin' then
    raise exception 'only an admin can delete channels';
  end if;
  if v_slug = 'general' then raise exception 'the general channel stays'; end if;

  select id into v_general from community_channel
  where community_id = v_community and slug = 'general';
  update post set channel_id = v_general where channel_id = p_channel_id;
  delete from community_channel where id = p_channel_id;
  perform _mod_log(v_community, 'edit_settings');
end;
$$;

create or replace function reorder_channels(p_community_id uuid, p_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
begin
  if community_role_of(p_community_id, auth.uid()) <> 'admin' then
    raise exception 'only an admin can reorder channels';
  end if;
  update community_channel ch set position = idx.ord
  from (select unnest(p_ids) as id, generate_subscripts(p_ids, 1) as ord) idx
  where ch.id = idx.id and ch.community_id = p_community_id;
end;
$$;

revoke all on function community_channels(uuid)                      from public;
revoke all on function create_channel(uuid, text, text, text, boolean) from public;
revoke all on function update_channel(uuid, text, text, boolean)     from public;
revoke all on function delete_channel(uuid)                          from public;
revoke all on function reorder_channels(uuid, uuid[])                from public;
grant execute on function community_channels(uuid)                    to authenticated;
grant execute on function create_channel(uuid, text, text, text, boolean) to authenticated;
grant execute on function update_channel(uuid, text, text, boolean)   to authenticated;
grant execute on function delete_channel(uuid)                        to authenticated;
grant execute on function reorder_channels(uuid, uuid[])              to authenticated;

-- ── community_feed keeps its signature; gains channel columns. A new
--    community_channel_feed filters to one channel. ──────────────────────
drop function if exists community_feed(uuid, timestamptz, int);
create or replace function community_feed(
  p_community_id uuid,
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, is_pinned boolean,
  label text, label_note text, author_flair text,
  channel_id uuid, channel_name text
)
language sql stable security definer set search_path = public as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form, false,
    pl.label, pl.note,
    (select cm.flair from community_member cm
     where cm.community_id = p_community_id and cm.member_id = p.author_id),
    p.channel_id, ch.name
  from post p
  join profile a on a.id = p.author_id
  left join post_label pl on pl.post_id = p.id
  left join community_channel ch on ch.id = p.channel_id
  where p.community_id = p_community_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
grant execute on function community_feed(uuid, timestamptz, int) to authenticated;

create or replace function community_channel_feed(
  p_channel_id uuid,
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, is_pinned boolean,
  label text, label_note text, author_flair text,
  channel_id uuid, channel_name text
)
language sql stable security definer set search_path = public as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form, false,
    pl.label, pl.note,
    (select cm.flair from community_member cm
     where cm.community_id = ch0.community_id and cm.member_id = p.author_id),
    p.channel_id, ch0.name
  from post p
  join community_channel ch0 on ch0.id = p.channel_id
  join profile a on a.id = p.author_id
  left join post_label pl on pl.post_id = p.id
  where p.channel_id = p_channel_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
revoke all on function community_channel_feed(uuid, timestamptz, int) from public;
grant execute on function community_channel_feed(uuid, timestamptz, int) to authenticated;
