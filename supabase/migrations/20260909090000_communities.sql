-- Peak — Phase 4-0: community core.
--
-- The smallest recognizable community: create one, join/leave, browse a
-- directory, and a per-community feed built on the existing `post` table.
-- Channels, events, wiki, roles beyond creator=admin, the transparent mod log,
-- and request approval land in later 4-x slices.

create type community_join_policy   as enum ('open', 'request', 'invite');
create type community_role          as enum ('member', 'moderator', 'admin');
create type community_member_state  as enum ('active', 'request', 'banned');

create table community (
  id          uuid primary key default gen_random_uuid(),
  slug        citext not null unique check (slug ~ '^[a-z0-9][a-z0-9_-]{1,30}$'),
  name        text not null check (char_length(name) between 1 and 60),
  description text not null default '' check (char_length(description) <= 2000),
  topics      text[] not null default '{}',
  join_policy community_join_policy not null default 'open',
  is_nsfw     boolean not null default false,
  is_listed   boolean not null default true,   -- appears in the directory
  created_by  uuid references profile (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index community_topics_gin on community using gin (topics);
create index community_name_trgm on community (lower(name));

create table community_member (
  community_id uuid not null references community (id) on delete cascade,
  member_id    uuid not null references profile (id) on delete cascade,
  role         community_role not null default 'member',
  state        community_member_state not null default 'active',
  flair        text check (char_length(flair) <= 40),
  joined_at    timestamptz not null default now(),
  primary key (community_id, member_id)
);
create index community_member_by_member
  on community_member (member_id) where state = 'active';

-- ── post gains an optional community ─────────────────────────────────────
alter table post add column community_id uuid references community (id) on delete cascade;
create index post_community_created
  on post (community_id, created_at desc)
  where deleted_at is null and community_id is not null and reply_to is null;

-- ── RLS ─────────────────────────────────────────────────────────────────
alter table community        enable row level security;
alter table community_member enable row level security;

-- helper: is `viewer` an active member of `p_community`?
create or replace function is_community_member(p_community uuid, viewer uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from community_member cm
    where cm.community_id = p_community and cm.member_id = viewer
      and cm.state = 'active'
  );
$$;

-- helper: can `viewer` see `p_community` at all? (listed/open, or a member)
create or replace function can_view_community(p_community community, viewer uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_community.join_policy <> 'invite'
    or p_community.is_listed
    or is_community_member(p_community.id, viewer)
    or p_community.created_by = viewer;
$$;

create policy community_select on community for select
  using (can_view_community(community, auth.uid()));
create policy community_insert on community for insert to authenticated
  with check (created_by = auth.uid());
-- edits go through set_community_settings (admin-gated); no blanket update.

create policy community_member_select on community_member for select using (
  member_id = auth.uid()
  or exists (
    select 1 from community_member me
    where me.community_id = community_member.community_id
      and me.member_id = auth.uid() and me.state = 'active'
  )
);
-- writes go through the RPCs (join/leave/role) — deny direct.

-- ── can_view_post learns about community posts ──────────────────────────
create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    and case
      when p_post.community_id is not null then (
        p_post.author_id = viewer
        or exists (
          select 1 from community c
          where c.id = p_post.community_id
            and (c.join_policy = 'open' or is_community_member(c.id, viewer))
        )
      )
      else (
        p_post.author_id = viewer
        or (p_post.visibility = 'public')
        or (p_post.visibility = 'followers'
            and exists (select 1 from follow f
                        where f.follower_id = viewer and f.followee_id = p_post.author_id))
        or (p_post.visibility = 'mentioned'
            and exists (select 1 from mention m
                        where m.post_id = p_post.id and m.mentioned_id = viewer))
        or (p_post.visibility = 'circles'
            and exists (
              select 1 from post_audience pa
              join circle_member cm on cm.circle_id = pa.circle_id
              where pa.post_id = p_post.id and cm.member_id = viewer))
        or (p_post.visibility = 'circles'
            and exists (
              select 1 from post_audience pa
              join circle c on c.id = pa.circle_id
              where pa.post_id = p_post.id and c.is_public))
      )
    end;
$$;

-- posting into a community requires active membership
drop policy post_insert on post;
create policy post_insert on post for insert with check (
  author_id = auth.uid()
  and exists (select 1 from persona pe
              where pe.id = persona_id and pe.account_id = auth.uid())
  and (community_id is null or is_community_member(community_id, auth.uid()))
);

-- ── community RPCs ──────────────────────────────────────────────────────
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

  return v_id;
end;
$$;

create or replace function join_community(p_community_id uuid)
returns community_member_state
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_policy community_join_policy;
  v_state community_member_state;
begin
  if v_me is null then raise exception 'not authenticated'; end if;

  select join_policy into v_policy from community where id = p_community_id;
  if v_policy is null then raise exception 'no such community'; end if;
  if v_policy = 'invite' then raise exception 'this community is invite-only'; end if;

  -- banned members can't rejoin themselves
  if exists (select 1 from community_member
             where community_id = p_community_id and member_id = v_me and state = 'banned') then
    raise exception 'you can''t join this community';
  end if;

  v_state := (case when v_policy = 'open' then 'active' else 'request' end)::community_member_state;
  insert into community_member (community_id, member_id, state)
  values (p_community_id, v_me, v_state)
  on conflict (community_id, member_id) do nothing;

  select state into v_state from community_member
  where community_id = p_community_id and member_id = v_me;
  return v_state;
end;
$$;

create or replace function leave_community(p_community_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  -- the last admin can't just walk out
  if exists (
    select 1 from community_member
    where community_id = p_community_id and member_id = v_me
      and role = 'admin' and state = 'active'
  ) and (
    select count(*) from community_member
    where community_id = p_community_id and role = 'admin' and state = 'active'
  ) = 1 then
    raise exception 'promote another admin before you leave';
  end if;

  delete from community_member
  where community_id = p_community_id and member_id = v_me;
end;
$$;

-- community detail + the viewer's relationship to it
create or replace function community_view(p_slug citext)
returns table (
  id uuid, slug citext, name text, description text, topics text[],
  join_policy community_join_policy, is_nsfw boolean, created_at timestamptz,
  member_count int, my_role community_role, my_state community_member_state
)
language sql stable security definer set search_path = public as $$
  select
    c.id, c.slug, c.name, c.description, c.topics,
    c.join_policy, c.is_nsfw, c.created_at,
    (select count(*)::int from community_member cm
     where cm.community_id = c.id and cm.state = 'active'),
    (select cm.role from community_member cm
     where cm.community_id = c.id and cm.member_id = auth.uid()),
    (select cm.state from community_member cm
     where cm.community_id = c.id and cm.member_id = auth.uid())
  from community c
  where c.slug = p_slug and can_view_community(c, auth.uid());
$$;

-- the directory
create or replace function communities_browse(p_query text default '', p_limit int default 30)
returns table (
  id uuid, slug citext, name text, description text, topics text[],
  is_nsfw boolean, member_count int, is_member boolean
)
language sql stable security definer set search_path = public as $$
  select
    c.id, c.slug, c.name, c.description, c.topics, c.is_nsfw,
    (select count(*)::int from community_member cm
     where cm.community_id = c.id and cm.state = 'active'),
    is_community_member(c.id, auth.uid())
  from community c
  where c.is_listed
    and c.join_policy <> 'invite'
    and (
      btrim(p_query) = ''
      or c.name ilike '%' || btrim(p_query) || '%'
      or c.slug ilike btrim(p_query) || '%'
      or btrim(lower(p_query)) = any (c.topics)
    )
  order by (select count(*) from community_member cm
            where cm.community_id = c.id and cm.state = 'active') desc,
           c.created_at desc
  limit least(p_limit, 50);
$$;

create or replace function my_communities()
returns table (
  id uuid, slug citext, name text, my_role community_role,
  member_count int
)
language sql stable security definer set search_path = public as $$
  select c.id, c.slug, c.name, cm.role,
    (select count(*)::int from community_member x
     where x.community_id = c.id and x.state = 'active')
  from community_member cm
  join community c on c.id = cm.community_id
  where cm.member_id = auth.uid() and cm.state = 'active'
  order by c.name;
$$;

-- a community's feed (feed-shaped rows, same as posts_by)
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
  title text, long_form boolean, is_pinned boolean
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
    p.title, p.long_form, false
  from post p
  join profile a on a.id = p.author_id
  where p.community_id = p_community_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

revoke all on function create_community(text, text, text, text[], community_join_policy, boolean) from public;
revoke all on function join_community(uuid)   from public;
revoke all on function leave_community(uuid)  from public;
revoke all on function community_view(citext) from public;
revoke all on function communities_browse(text, int) from public;
revoke all on function my_communities()       from public;
revoke all on function community_feed(uuid, timestamptz, int) from public;
grant execute on function create_community(text, text, text, text[], community_join_policy, boolean) to authenticated;
grant execute on function join_community(uuid)   to authenticated;
grant execute on function leave_community(uuid)  to authenticated;
grant execute on function community_view(citext) to authenticated;
grant execute on function communities_browse(text, int) to authenticated;
grant execute on function my_communities()       to authenticated;
grant execute on function community_feed(uuid, timestamptz, int) to authenticated;

-- ── home feed + profile timeline exclude community posts ────────────────
drop function if exists feed_latest(timestamptz, int);
create or replace function feed_latest(
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
  title text, long_form boolean
)
language sql stable as $$
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
    p.title, p.long_form
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and (
      p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

drop function if exists posts_by(uuid, timestamptz, int);
create or replace function posts_by(
  p_author uuid, p_before timestamptz default now(), p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, is_pinned boolean
)
language sql stable as $$
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
    p.title, p.long_form,
    exists (select 1 from profile_pin pp
            where pp.owner_id = p_author and pp.post_id = p.id)
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_author
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
