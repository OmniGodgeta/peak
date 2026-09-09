-- Peak — Phase 4-2: the transparent mod log + labels instead of silent removals.
--
-- Every moderator action lands in `community_mod_log`, which any member can
-- read. Mods can attach a label to a post ("off-topic", "unverified", …)
-- instead of deleting it; a removal is still possible but it's logged too.

create type community_mod_action as enum (
  'approve_request', 'decline_request', 'set_role',
  'remove_member', 'ban_member', 'unban_member',
  'label_post', 'unlabel_post', 'remove_post', 'edit_settings'
);

-- community_can_moderate must be strictly boolean — a non-member's role is
-- null, and `null in (...)` is null, which `if not (...)` treats as false.
create or replace function community_can_moderate(p_community uuid, p_actor uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    community_role_of(p_community, p_actor) in ('moderator', 'admin'),
    false
  );
$$;

create table community_mod_log (
  id               uuid primary key default gen_random_uuid(),
  community_id     uuid not null references community (id) on delete cascade,
  actor_id         uuid references profile (id) on delete set null,
  action           community_mod_action not null,
  target_member_id uuid references profile (id) on delete set null,
  target_post_id   uuid references post (id) on delete set null,
  label            text,
  reason           text check (char_length(reason) <= 500),
  created_at       timestamptz not null default now()
);
create index community_mod_log_by_community
  on community_mod_log (community_id, created_at desc);

alter table community_mod_log enable row level security;
-- members read the log; nobody writes it directly (RPCs are SECURITY DEFINER).
create policy community_mod_log_select on community_mod_log for select
  using (is_community_member(community_id, auth.uid()));

-- one community label per post
create table post_label (
  post_id      uuid primary key references post (id) on delete cascade,
  community_id uuid not null references community (id) on delete cascade,
  label        text not null check (char_length(label) <= 40),
  note         text check (char_length(note) <= 280),
  labeled_by   uuid references profile (id) on delete set null,
  labeled_at   timestamptz not null default now()
);

alter table post_label enable row level security;
create policy post_label_select on post_label for select
  using (
    exists (select 1 from post p where p.id = post_id and can_view_post(p, auth.uid()))
  );

-- ── internal: append a log entry ───────────────────────────────────────
create or replace function _mod_log(
  p_community uuid,
  p_action community_mod_action,
  p_target_member uuid default null,
  p_target_post uuid default null,
  p_label text default null,
  p_reason text default null
)
returns void
language sql security definer set search_path = public as $$
  insert into community_mod_log
    (community_id, actor_id, action, target_member_id, target_post_id, label, reason)
  values
    (p_community, auth.uid(), p_action, p_target_member, p_target_post,
     p_label, nullif(btrim(p_reason), ''));
$$;

-- ── 4-1 RPCs, now logging (and taking an optional reason) ───────────────
create or replace function approve_request(p_community_id uuid, p_member_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  update community_member set state = 'active'
  where community_id = p_community_id and member_id = p_member_id and state = 'request';
  if found then
    perform _mod_log(p_community_id, 'approve_request', p_member_id);
  end if;
end;
$$;

drop function if exists decline_request(uuid, uuid);
create or replace function decline_request(
  p_community_id uuid, p_member_id uuid, p_reason text default null
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  delete from community_member
  where community_id = p_community_id and member_id = p_member_id and state = 'request';
  if found then
    perform _mod_log(p_community_id, 'decline_request', p_member_id, null, null, p_reason);
  end if;
end;
$$;

create or replace function set_member_role(
  p_community_id uuid, p_member_id uuid, p_role community_role
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_current community_role;
begin
  if community_role_of(p_community_id, auth.uid()) <> 'admin' then
    raise exception 'only an admin can change roles';
  end if;
  select role into v_current from community_member
  where community_id = p_community_id and member_id = p_member_id and state = 'active';
  if v_current is null then raise exception 'not an active member'; end if;
  if v_current = 'admin' and p_role <> 'admin'
     and community_active_admins(p_community_id) <= 1 then
    raise exception 'promote another admin first';
  end if;
  update community_member set role = p_role
  where community_id = p_community_id and member_id = p_member_id and state = 'active';
  perform _mod_log(p_community_id, 'set_role', p_member_id, null, p_role::text);
end;
$$;

drop function if exists remove_member(uuid, uuid, boolean);
create or replace function remove_member(
  p_community_id uuid,
  p_member_id uuid,
  p_ban boolean default false,
  p_reason text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_my_role community_role := community_role_of(p_community_id, v_me);
  v_target_role community_role;
begin
  if v_my_role is null or v_my_role = 'member' then
    raise exception 'not a moderator';
  end if;
  if p_member_id = v_me then
    raise exception 'use leave_community to leave';
  end if;
  select role into v_target_role from community_member
  where community_id = p_community_id and member_id = p_member_id;
  if v_target_role is null then return; end if;
  if v_my_role = 'moderator' and v_target_role <> 'member' then
    raise exception 'you can only remove members';
  end if;
  if v_target_role = 'admin' and community_active_admins(p_community_id) <= 1 then
    raise exception 'the last admin can''t be removed';
  end if;

  if p_ban then
    update community_member set state = 'banned', role = 'member'
    where community_id = p_community_id and member_id = p_member_id;
    perform _mod_log(p_community_id, 'ban_member', p_member_id, null, null, p_reason);
  else
    delete from community_member
    where community_id = p_community_id and member_id = p_member_id;
    perform _mod_log(p_community_id, 'remove_member', p_member_id, null, null, p_reason);
  end if;
end;
$$;

create or replace function unban_member(p_community_id uuid, p_member_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  delete from community_member
  where community_id = p_community_id and member_id = p_member_id and state = 'banned';
  if found then
    perform _mod_log(p_community_id, 'unban_member', p_member_id);
  end if;
end;
$$;

create or replace function set_community_settings(
  p_community_id uuid, p_name text, p_description text, p_topics text[],
  p_join_policy community_join_policy, p_nsfw boolean, p_is_listed boolean
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if community_role_of(p_community_id, auth.uid()) <> 'admin' then
    raise exception 'only an admin can edit the community';
  end if;
  update community set
    name = btrim(p_name),
    description = coalesce(btrim(p_description), ''),
    topics = coalesce(p_topics, '{}'),
    join_policy = p_join_policy,
    is_nsfw = p_nsfw,
    is_listed = p_is_listed
  where id = p_community_id;
  perform _mod_log(p_community_id, 'edit_settings');
end;
$$;

-- ── labels + moderator post removal ───────────────────────────────────
create or replace function label_post(
  p_post_id uuid, p_label text, p_note text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from post where id = p_post_id;
  if v_community is null then raise exception 'not a community post'; end if;
  if not community_can_moderate(v_community, auth.uid()) then
    raise exception 'not a moderator';
  end if;

  insert into post_label (post_id, community_id, label, note, labeled_by)
  values (p_post_id, v_community, btrim(p_label), nullif(btrim(p_note), ''), auth.uid())
  on conflict (post_id) do update
    set label = excluded.label, note = excluded.note,
        labeled_by = excluded.labeled_by, labeled_at = now();

  perform _mod_log(v_community, 'label_post', null, p_post_id, btrim(p_label), p_note);
end;
$$;

create or replace function unlabel_post(p_post_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from post_label where post_id = p_post_id;
  if v_community is null then return; end if;
  if not community_can_moderate(v_community, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  delete from post_label where post_id = p_post_id;
  perform _mod_log(v_community, 'unlabel_post', null, p_post_id);
end;
$$;

create or replace function moderate_remove_post(
  p_post_id uuid, p_reason text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid; v_author uuid;
begin
  select community_id, author_id into v_community, v_author
  from post where id = p_post_id and deleted_at is null;
  if v_community is null then raise exception 'not an active community post'; end if;
  if not community_can_moderate(v_community, auth.uid()) then
    raise exception 'not a moderator';
  end if;

  update post set deleted_at = now() where id = p_post_id;
  perform _mod_log(v_community, 'remove_post', v_author, p_post_id, null, p_reason);
end;
$$;

-- ── the mod log reader ───────────────────────────────────────────────
create or replace function community_mod_log(
  p_community_id uuid, p_limit int default 50
)
returns table (
  id uuid, action community_mod_action, label text, reason text,
  created_at timestamptz,
  actor_handle citext, actor_display_name text,
  target_handle citext, target_display_name text,
  target_post_id uuid
)
language sql stable security definer set search_path = public as $$
  select
    ml.id, ml.action, ml.label, ml.reason, ml.created_at,
    act.handle, act.display_name,
    tgt.handle, tgt.display_name,
    ml.target_post_id
  from community_mod_log ml
  left join profile act on act.id = ml.actor_id
  left join profile tgt on tgt.id = ml.target_member_id
  where ml.community_id = p_community_id
    and is_community_member(p_community_id, auth.uid())
  order by ml.created_at desc
  limit least(p_limit, 200);
$$;

revoke all on function decline_request(uuid, uuid, text)     from public;
revoke all on function remove_member(uuid, uuid, boolean, text) from public;
revoke all on function label_post(uuid, text, text)          from public;
revoke all on function unlabel_post(uuid)                    from public;
revoke all on function moderate_remove_post(uuid, text)      from public;
revoke all on function community_mod_log(uuid, int)          from public;
grant execute on function decline_request(uuid, uuid, text)     to authenticated;
grant execute on function remove_member(uuid, uuid, boolean, text) to authenticated;
grant execute on function label_post(uuid, text, text)          to authenticated;
grant execute on function unlabel_post(uuid)                    to authenticated;
grant execute on function moderate_remove_post(uuid, text)      to authenticated;
grant execute on function community_mod_log(uuid, int)          to authenticated;

-- ── community_feed carries the label ─────────────────────────────────
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
  label text, label_note text
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
    pl.label, pl.note
  from post p
  join profile a on a.id = p.author_id
  left join post_label pl on pl.post_id = p.id
  where p.community_id = p_community_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
