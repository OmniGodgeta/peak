-- Peak — Phase 4-1: community moderation.
--
-- Request approval, the member roster, role management (promote to mod / admin),
-- and remove / ban / unban. The transparent mod log + labels-instead-of-removal
-- are 4-2.

-- ── permission helpers ──────────────────────────────────────────────────
create or replace function community_role_of(p_community uuid, p_actor uuid)
returns community_role
language sql stable security definer set search_path = public as $$
  select cm.role from community_member cm
  where cm.community_id = p_community and cm.member_id = p_actor
    and cm.state = 'active';
$$;

create or replace function community_can_moderate(p_community uuid, p_actor uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select community_role_of(p_community, p_actor) in ('moderator', 'admin');
$$;

create or replace function community_active_admins(p_community uuid)
returns integer
language sql stable security definer set search_path = public as $$
  select count(*)::int from community_member cm
  where cm.community_id = p_community and cm.role = 'admin' and cm.state = 'active';
$$;

-- ── community_view gains a pending-request count (mods only) ─────────────
drop function if exists community_view(citext);
create or replace function community_view(p_slug citext)
returns table (
  id uuid, slug citext, name text, description text, topics text[],
  join_policy community_join_policy, is_nsfw boolean, is_listed boolean,
  created_at timestamptz, member_count int, pending_count int,
  my_role community_role, my_state community_member_state
)
language sql stable security definer set search_path = public as $$
  select
    c.id, c.slug, c.name, c.description, c.topics,
    c.join_policy, c.is_nsfw, c.is_listed, c.created_at,
    (select count(*)::int from community_member cm
     where cm.community_id = c.id and cm.state = 'active'),
    case when community_can_moderate(c.id, auth.uid())
         then (select count(*)::int from community_member cm
               where cm.community_id = c.id and cm.state = 'request')
         else 0 end,
    community_role_of(c.id, auth.uid()),
    (select cm.state from community_member cm
     where cm.community_id = c.id and cm.member_id = auth.uid())
  from community c
  where c.slug = p_slug and can_view_community(c, auth.uid());
$$;

-- ── the roster (any active member can see it) ──────────────────────────
create or replace function community_roster(
  p_community_id uuid,
  p_limit int default 100
)
returns table (
  member_id uuid, handle citext, domain text, display_name text,
  avatar_path text, role community_role, flair text, since timestamptz
)
language sql stable security definer set search_path = public as $$
  select
    p.id, p.handle, p.domain, p.display_name, p.avatar_path,
    cm.role, cm.flair, cm.joined_at
  from community_member cm
  join profile p on p.id = cm.member_id
  where cm.community_id = p_community_id
    and cm.state = 'active'
    and is_community_member(p_community_id, auth.uid())
  order by
    array_position(array['admin','moderator','member']::community_role[], cm.role),
    cm.joined_at
  limit least(p_limit, 500);
$$;

-- ── pending join requests (moderators) ─────────────────────────────────
create or replace function community_pending_requests(p_community_id uuid)
returns table (
  member_id uuid, handle citext, domain text, display_name text,
  avatar_path text, requested_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.id, p.handle, p.domain, p.display_name, p.avatar_path, cm.joined_at
  from community_member cm
  join profile p on p.id = cm.member_id
  where cm.community_id = p_community_id
    and cm.state = 'request'
    and community_can_moderate(p_community_id, auth.uid())
  order by cm.joined_at;
$$;

create or replace function approve_request(p_community_id uuid, p_member_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  update community_member set state = 'active'
  where community_id = p_community_id and member_id = p_member_id
    and state = 'request';
end;
$$;

create or replace function decline_request(p_community_id uuid, p_member_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not community_can_moderate(p_community_id, auth.uid()) then
    raise exception 'not a moderator';
  end if;
  delete from community_member
  where community_id = p_community_id and member_id = p_member_id
    and state = 'request';
end;
$$;

-- ── role management (admins only) ─────────────────────────────────────
create or replace function set_member_role(
  p_community_id uuid,
  p_member_id uuid,
  p_role community_role
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_current community_role;
begin
  if community_role_of(p_community_id, v_me) <> 'admin' then
    raise exception 'only an admin can change roles';
  end if;

  select role into v_current from community_member
  where community_id = p_community_id and member_id = p_member_id and state = 'active';
  if v_current is null then raise exception 'not an active member'; end if;

  -- don't strip the community's last admin
  if v_current = 'admin' and p_role <> 'admin'
     and community_active_admins(p_community_id) <= 1 then
    raise exception 'promote another admin first';
  end if;

  update community_member set role = p_role
  where community_id = p_community_id and member_id = p_member_id and state = 'active';
end;
$$;

-- ── remove / ban / unban ─────────────────────────────────────────────
create or replace function remove_member(
  p_community_id uuid,
  p_member_id uuid,
  p_ban boolean default false
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

  -- a moderator can't act on an admin or another moderator; only admins can
  if v_my_role = 'moderator' and v_target_role <> 'member' then
    raise exception 'you can only remove members';
  end if;
  if v_target_role = 'admin' and community_active_admins(p_community_id) <= 1 then
    raise exception 'the last admin can''t be removed';
  end if;

  if p_ban then
    update community_member set state = 'banned', role = 'member'
    where community_id = p_community_id and member_id = p_member_id;
  else
    delete from community_member
    where community_id = p_community_id and member_id = p_member_id;
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
end;
$$;

create or replace function community_banned(p_community_id uuid)
returns table (
  member_id uuid, handle citext, domain text, display_name text, avatar_path text
)
language sql stable security definer set search_path = public as $$
  select p.id, p.handle, p.domain, p.display_name, p.avatar_path
  from community_member cm
  join profile p on p.id = cm.member_id
  where cm.community_id = p_community_id
    and cm.state = 'banned'
    and community_can_moderate(p_community_id, auth.uid())
  order by p.handle;
$$;

-- ── edit community settings (admins) ─────────────────────────────────
create or replace function set_community_settings(
  p_community_id uuid,
  p_name text,
  p_description text,
  p_topics text[],
  p_join_policy community_join_policy,
  p_nsfw boolean,
  p_is_listed boolean
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
end;
$$;

revoke all on function community_roster(uuid, int)           from public;
revoke all on function community_pending_requests(uuid)      from public;
revoke all on function approve_request(uuid, uuid)           from public;
revoke all on function decline_request(uuid, uuid)           from public;
revoke all on function set_member_role(uuid, uuid, community_role) from public;
revoke all on function remove_member(uuid, uuid, boolean)    from public;
revoke all on function unban_member(uuid, uuid)              from public;
revoke all on function community_banned(uuid)               from public;
revoke all on function set_community_settings(uuid, text, text, text[], community_join_policy, boolean, boolean) from public;
grant execute on function community_roster(uuid, int)           to authenticated;
grant execute on function community_pending_requests(uuid)      to authenticated;
grant execute on function approve_request(uuid, uuid)           to authenticated;
grant execute on function decline_request(uuid, uuid)           to authenticated;
grant execute on function set_member_role(uuid, uuid, community_role) to authenticated;
grant execute on function remove_member(uuid, uuid, boolean)    to authenticated;
grant execute on function unban_member(uuid, uuid)              to authenticated;
grant execute on function community_banned(uuid)               to authenticated;
grant execute on function set_community_settings(uuid, text, text, text[], community_join_policy, boolean, boolean) to authenticated;
