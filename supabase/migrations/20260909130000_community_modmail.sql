-- Peak — Phase 4-3b: modmail.
--
-- A private thread between one member and a community's moderator team. Used for
-- questions, reports the member doesn't want public, and ban appeals (a banned
-- member can still open one). Kept out of the public `community_mod_log` on
-- purpose — modmail is private to the member and the mods.

create type modmail_state as enum ('open', 'closed');

create table modmail_thread (
  id              uuid primary key default gen_random_uuid(),
  community_id    uuid not null references community (id) on delete cascade,
  member_id       uuid not null references profile (id) on delete cascade,
  subject         text not null check (char_length(subject) between 1 and 200),
  state           modmail_state not null default 'open',
  created_at      timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  closed_at       timestamptz,
  closed_by       uuid references profile (id) on delete set null
);
create index modmail_thread_by_community on modmail_thread (community_id, last_message_at desc);
create index modmail_thread_by_member    on modmail_thread (member_id, last_message_at desc);

create table modmail_message (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references modmail_thread (id) on delete cascade,
  sender_id  uuid references profile (id) on delete set null,
  from_mod   boolean not null,
  body       text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index modmail_message_by_thread on modmail_message (thread_id, created_at);

alter table modmail_thread  enable row level security;
alter table modmail_message enable row level security;

-- helper: can `viewer` see this thread? (the member on it, or a mod of its community)
create or replace function modmail_can_see(p_thread modmail_thread, viewer uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_thread.member_id = viewer
      or community_can_moderate(p_thread.community_id, viewer);
$$;

create policy modmail_thread_select on modmail_thread for select
  using (modmail_can_see(modmail_thread.*, auth.uid()));

create policy modmail_message_select on modmail_message for select
  using (exists (
    select 1 from modmail_thread t
    where t.id = modmail_message.thread_id and modmail_can_see(t.*, auth.uid())
  ));
-- writes go through the SECURITY DEFINER RPCs below only.

-- ── open a thread ──────────────────────────────────────────────────────
create or replace function start_modmail(
  p_community_id uuid, p_subject text, p_body text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_community community;
  v_thread uuid;
begin
  select * into v_community from community where id = p_community_id;
  if v_community.id is null then raise exception 'no such community'; end if;
  -- a member (even a banned one, for appeals) or anyone who can see the community
  if not can_view_community(v_community, v_me)
     and not exists (select 1 from community_member cm
                     where cm.community_id = p_community_id and cm.member_id = v_me) then
    raise exception 'community not available';
  end if;
  if community_can_moderate(p_community_id, v_me) then
    raise exception 'moderators reply to modmail, they do not open it';
  end if;
  if btrim(coalesce(p_body, '')) = '' then raise exception 'message is empty'; end if;

  insert into modmail_thread (community_id, member_id, subject)
  values (p_community_id, v_me, left(btrim(p_subject), 200))
  returning id into v_thread;

  insert into modmail_message (thread_id, sender_id, from_mod, body)
  values (v_thread, v_me, false, btrim(p_body));

  return v_thread;
end;
$$;

-- ── reply (member or mod) ──────────────────────────────────────────────
create or replace function modmail_reply(p_thread_id uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_thread modmail_thread;
  v_from_mod boolean;
  v_msg uuid;
begin
  select * into v_thread from modmail_thread where id = p_thread_id;
  if v_thread.id is null then raise exception 'no such thread'; end if;
  if v_thread.state = 'closed' then raise exception 'this thread is closed'; end if;
  if btrim(coalesce(p_body, '')) = '' then raise exception 'message is empty'; end if;

  if v_thread.member_id = v_me then
    v_from_mod := false;
  elsif community_can_moderate(v_thread.community_id, v_me) then
    v_from_mod := true;
  else
    raise exception 'not on this thread';
  end if;

  insert into modmail_message (thread_id, sender_id, from_mod, body)
  values (p_thread_id, v_me, v_from_mod, btrim(p_body))
  returning id into v_msg;

  update modmail_thread set last_message_at = now() where id = p_thread_id;
  return v_msg;
end;
$$;

-- ── close / reopen (member or mod) ─────────────────────────────────────
create or replace function set_modmail_state(p_thread_id uuid, p_open boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_thread modmail_thread;
begin
  select * into v_thread from modmail_thread where id = p_thread_id;
  if v_thread.id is null then raise exception 'no such thread'; end if;
  if v_thread.member_id <> v_me
     and not community_can_moderate(v_thread.community_id, v_me) then
    raise exception 'not on this thread';
  end if;
  if p_open then
    update modmail_thread set state = 'open', closed_at = null, closed_by = null
    where id = p_thread_id;
  else
    update modmail_thread set state = 'closed', closed_at = now(), closed_by = v_me
    where id = p_thread_id;
  end if;
end;
$$;

-- ── the member's own threads, across communities ───────────────────────
create or replace function my_modmail_threads()
returns table (
  id uuid, community_id uuid, community_slug citext, community_name text,
  subject text, state modmail_state, created_at timestamptz,
  last_message_at timestamptz, message_count int,
  last_snippet text, last_from_mod boolean
)
language sql stable security definer set search_path = public as $$
  select
    t.id, t.community_id, c.slug, c.name,
    t.subject, t.state, t.created_at, t.last_message_at,
    (select count(*)::int from modmail_message m where m.thread_id = t.id),
    (select left(m.body, 140) from modmail_message m
     where m.thread_id = t.id order by m.created_at desc limit 1),
    (select m.from_mod from modmail_message m
     where m.thread_id = t.id order by m.created_at desc limit 1)
  from modmail_thread t
  join community c on c.id = t.community_id
  where t.member_id = auth.uid()
  order by t.last_message_at desc;
$$;

-- ── a community's modmail queue (moderators) ───────────────────────────
create or replace function community_modmail_threads(
  p_community_id uuid, p_state text default 'open'
)
returns table (
  id uuid, subject text, state modmail_state,
  created_at timestamptz, last_message_at timestamptz, message_count int,
  last_snippet text, last_from_mod boolean,
  member_id uuid, member_handle citext, member_domain text,
  member_display_name text, member_avatar_path text,
  member_state community_member_state
)
language sql stable security definer set search_path = public as $$
  select
    t.id, t.subject, t.state, t.created_at, t.last_message_at,
    (select count(*)::int from modmail_message m where m.thread_id = t.id),
    (select left(m.body, 140) from modmail_message m
     where m.thread_id = t.id order by m.created_at desc limit 1),
    (select m.from_mod from modmail_message m
     where m.thread_id = t.id order by m.created_at desc limit 1),
    p.id, p.handle, p.domain, p.display_name, p.avatar_path,
    (select cm.state from community_member cm
     where cm.community_id = t.community_id and cm.member_id = t.member_id)
  from modmail_thread t
  join profile p on p.id = t.member_id
  where t.community_id = p_community_id
    and community_can_moderate(p_community_id, auth.uid())
    and (p_state = 'all' or t.state::text = p_state)
  order by t.last_message_at desc;
$$;

-- ── one thread's messages ─────────────────────────────────────────────
create or replace function modmail_messages(p_thread_id uuid)
returns table (
  id uuid, sender_id uuid, sender_handle citext, sender_display_name text,
  sender_avatar_path text, from_mod boolean, body text, created_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select
    m.id, m.sender_id, s.handle, s.display_name, s.avatar_path,
    m.from_mod, m.body, m.created_at
  from modmail_message m
  join modmail_thread t on t.id = m.thread_id
  left join profile s on s.id = m.sender_id
  where m.thread_id = p_thread_id
    and (t.member_id = auth.uid()
         or community_can_moderate(t.community_id, auth.uid()))
  order by m.created_at;
$$;

revoke all on function start_modmail(uuid, text, text)          from public;
revoke all on function modmail_reply(uuid, text)                from public;
revoke all on function set_modmail_state(uuid, boolean)         from public;
revoke all on function my_modmail_threads()                     from public;
revoke all on function community_modmail_threads(uuid, text)    from public;
revoke all on function modmail_messages(uuid)                   from public;
grant execute on function start_modmail(uuid, text, text)        to authenticated;
grant execute on function modmail_reply(uuid, text)              to authenticated;
grant execute on function set_modmail_state(uuid, boolean)       to authenticated;
grant execute on function my_modmail_threads()                   to authenticated;
grant execute on function community_modmail_threads(uuid, text)  to authenticated;
grant execute on function modmail_messages(uuid)                 to authenticated;
