-- Peak — Phase 4-4b: community events + RSVP.
--
-- An event belongs to a community (optionally to a channel). Any active member
-- can create one; the creator or a moderator can edit or cancel it. Members
-- RSVP going / maybe / not going. Calendar export is done client-side (ICS +
-- a Google Calendar link) so there's no server dependency.

create type rsvp_status as enum ('going', 'maybe', 'not_going');

create table community_event (
  id           uuid primary key default gen_random_uuid(),
  community_id uuid not null references community (id) on delete cascade,
  channel_id   uuid references community_channel (id) on delete set null,
  created_by   uuid references profile (id) on delete set null,
  title        text not null check (char_length(title) between 1 and 140),
  description  text not null default '' check (char_length(description) <= 4000),
  location     text check (char_length(location) <= 280),
  starts_at    timestamptz not null,
  ends_at      timestamptz,
  timezone     text not null default 'UTC' check (char_length(timezone) <= 60),
  created_at   timestamptz not null default now(),
  canceled_at  timestamptz,
  check (ends_at is null or ends_at >= starts_at)
);
create index community_event_by_community
  on community_event (community_id, starts_at);

create table event_rsvp (
  event_id   uuid not null references community_event (id) on delete cascade,
  member_id  uuid not null references profile (id) on delete cascade,
  status     rsvp_status not null,
  updated_at timestamptz not null default now(),
  primary key (event_id, member_id)
);
create index event_rsvp_by_member on event_rsvp (member_id);

alter table community_event enable row level security;
alter table event_rsvp      enable row level security;

-- an event is visible to anyone who can see its community
create policy community_event_select on community_event for select using (
  exists (select 1 from community c
          where c.id = community_id and can_view_community(c, auth.uid()))
);

-- RSVPs are visible to community members (so "who's going" works) and to their
-- own owner
create policy event_rsvp_select on event_rsvp for select using (
  member_id = auth.uid()
  or exists (
    select 1 from community_event e
    where e.id = event_id and is_community_member(e.community_id, auth.uid())
  )
);
-- writes via the RPCs below only

-- ── helper: creator or moderator of the event's community ──────────────
create or replace function can_manage_event(p_event uuid, p_actor uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from community_event e
    where e.id = p_event
      and (e.created_by = p_actor
           or community_can_moderate(e.community_id, p_actor))
  );
$$;

-- ── event RPCs ────────────────────────────────────────────────────────
create or replace function create_event(
  p_community_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_description text default '',
  p_location text default null,
  p_ends_at timestamptz default null,
  p_timezone text default 'UTC',
  p_channel_id uuid default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_community_member(p_community_id, auth.uid()) then
    raise exception 'only a member can create an event';
  end if;
  if p_channel_id is not null and not exists (
    select 1 from community_channel where id = p_channel_id
      and community_id = p_community_id
  ) then
    raise exception 'that channel is not in this community';
  end if;
  insert into community_event
    (community_id, channel_id, created_by, title, description, location,
     starts_at, ends_at, timezone)
  values (
    p_community_id, p_channel_id, auth.uid(), btrim(p_title),
    coalesce(btrim(p_description), ''), nullif(btrim(p_location), ''),
    p_starts_at, p_ends_at, coalesce(nullif(btrim(p_timezone), ''), 'UTC')
  )
  returning id into v_id;

  -- the creator is going by default
  insert into event_rsvp (event_id, member_id, status)
  values (v_id, auth.uid(), 'going');

  return v_id;
end;
$$;

create or replace function update_event(
  p_event_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_description text default '',
  p_location text default null,
  p_ends_at timestamptz default null,
  p_timezone text default 'UTC',
  p_channel_id uuid default null
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_event(p_event_id, auth.uid()) then
    raise exception 'not allowed to edit this event';
  end if;
  update community_event set
    title = btrim(p_title),
    description = coalesce(btrim(p_description), ''),
    location = nullif(btrim(p_location), ''),
    starts_at = p_starts_at,
    ends_at = p_ends_at,
    timezone = coalesce(nullif(btrim(p_timezone), ''), 'UTC'),
    channel_id = p_channel_id
  where id = p_event_id;
end;
$$;

create or replace function cancel_event(p_event_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_event(p_event_id, auth.uid()) then
    raise exception 'not allowed to cancel this event';
  end if;
  update community_event set canceled_at = now()
  where id = p_event_id and canceled_at is null;
end;
$$;

create or replace function rsvp_event(p_event_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_community uuid;
begin
  select community_id into v_community from community_event
  where id = p_event_id and canceled_at is null;
  if v_community is null then raise exception 'no such event'; end if;
  if not exists (select 1 from community c
                 where c.id = v_community and can_view_community(c, auth.uid())) then
    raise exception 'event not available';
  end if;

  if p_status = 'none' then
    delete from event_rsvp where event_id = p_event_id and member_id = auth.uid();
    return;
  end if;

  insert into event_rsvp (event_id, member_id, status)
  values (p_event_id, auth.uid(), p_status::rsvp_status)
  on conflict (event_id, member_id)
    do update set status = excluded.status, updated_at = now();
end;
$$;

-- ── readers ───────────────────────────────────────────────────────────
create or replace function community_events(
  p_community_id uuid, p_include_past boolean default false
)
returns table (
  id uuid, title text, description text, location text,
  starts_at timestamptz, ends_at timestamptz, timezone text,
  canceled boolean, channel_id uuid, channel_name text,
  creator_handle citext, creator_display_name text,
  going_count int, maybe_count int, my_status text
)
language sql stable security definer set search_path = public as $$
  select
    e.id, e.title, e.description, e.location,
    e.starts_at, e.ends_at, e.timezone,
    (e.canceled_at is not null), e.channel_id, ch.name,
    cr.handle, cr.display_name,
    (select count(*)::int from event_rsvp r
     where r.event_id = e.id and r.status = 'going'),
    (select count(*)::int from event_rsvp r
     where r.event_id = e.id and r.status = 'maybe'),
    (select r.status::text from event_rsvp r
     where r.event_id = e.id and r.member_id = auth.uid())
  from community_event e
  join community c on c.id = e.community_id
  left join community_channel ch on ch.id = e.channel_id
  left join profile cr on cr.id = e.created_by
  where e.community_id = p_community_id
    and can_view_community(c, auth.uid())
    and (p_include_past
         or e.canceled_at is not null
         or coalesce(e.ends_at, e.starts_at) >= now() - interval '2 hours')
  order by e.starts_at;
$$;

create or replace function event_attendees(
  p_event_id uuid, p_status text default 'going'
)
returns table (
  member_id uuid, handle citext, domain text, display_name text,
  avatar_path text, status text
)
language sql stable security definer set search_path = public as $$
  select p.id, p.handle, p.domain, p.display_name, p.avatar_path, r.status::text
  from event_rsvp r
  join community_event e on e.id = r.event_id
  join profile p on p.id = r.member_id
  where r.event_id = p_event_id
    and is_community_member(e.community_id, auth.uid())
    and (p_status = 'all' or r.status::text = p_status)
  order by r.status, r.updated_at;
$$;

revoke all on function create_event(uuid, text, timestamptz, text, text, timestamptz, text, uuid) from public;
revoke all on function update_event(uuid, text, timestamptz, text, text, timestamptz, text, uuid) from public;
revoke all on function cancel_event(uuid)                    from public;
revoke all on function rsvp_event(uuid, text)                from public;
revoke all on function community_events(uuid, boolean)       from public;
revoke all on function event_attendees(uuid, text)           from public;
revoke all on function can_manage_event(uuid, uuid)          from public;
grant execute on function create_event(uuid, text, timestamptz, text, text, timestamptz, text, uuid) to authenticated;
grant execute on function update_event(uuid, text, timestamptz, text, text, timestamptz, text, uuid) to authenticated;
grant execute on function cancel_event(uuid)                  to authenticated;
grant execute on function rsvp_event(uuid, text)              to authenticated;
grant execute on function community_events(uuid, boolean)     to authenticated;
grant execute on function event_attendees(uuid, text)         to authenticated;
