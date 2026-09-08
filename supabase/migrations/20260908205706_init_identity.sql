-- Peak — Phase 0: identity, personas, circles, social graph
-- Forward-only. Every table has RLS enabled and deny-by-default.

-- ─────────────────────────────────────────────────────────────────────────────
-- Extensions
-- ─────────────────────────────────────────────────────────────────────────────
create extension if not exists "pgcrypto";
create extension if not exists "citext";

-- ─────────────────────────────────────────────────────────────────────────────
-- Enums
-- ─────────────────────────────────────────────────────────────────────────────
create type account_kind as enum ('adult', 'teen');
create type verification_tier as enum ('none', 'device_attested', 'id_verified');

-- ─────────────────────────────────────────────────────────────────────────────
-- profile: one row per auth user. The "account".
-- ─────────────────────────────────────────────────────────────────────────────
create table profile (
  id                uuid primary key references auth.users (id) on delete cascade,
  handle            citext not null unique
                      check (handle ~ '^[a-z0-9_]{2,30}$'),
  display_name      text not null default '' check (char_length(display_name) <= 80),
  bio               text not null default '' check (char_length(bio) <= 500),
  avatar_path       text,
  banner_path       text,
  pronouns          text check (char_length(pronouns) <= 40),
  location_coarse   text check (char_length(location_coarse) <= 80),
  links             jsonb not null default '[]'::jsonb,
  account_kind      account_kind not null default 'adult',
  verification      verification_tier not null default 'none',
  show_follow_counts boolean not null default false,
  is_discoverable   boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table profile is 'One row per account. Handle is unique per instance; no real-name requirement.';

-- keep updated_at fresh
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profile_updated_at before update on profile
  for each row execute function set_updated_at();

-- teen accounts are private + non-discoverable by default
create or replace function enforce_teen_defaults() returns trigger
language plpgsql as $$
begin
  if new.account_kind = 'teen' then
    new.is_discoverable = false;
  end if;
  return new;
end;
$$;

create trigger profile_teen_defaults before insert or update on profile
  for each row execute function enforce_teen_defaults();

-- ─────────────────────────────────────────────────────────────────────────────
-- persona: a face of an account (personal, a project, …). One default per account.
-- Phase 6 exposes switching; Phase 0 creates exactly one.
-- ─────────────────────────────────────────────────────────────────────────────
create table persona (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references profile (id) on delete cascade,
  label        text not null default 'main' check (char_length(label) <= 40),
  is_default   boolean not null default true,
  created_at   timestamptz not null default now()
);

create unique index persona_one_default_per_account
  on persona (account_id) where is_default;

-- ─────────────────────────────────────────────────────────────────────────────
-- circle: an audience bucket owned by an account. "Public" is just a circle.
-- ─────────────────────────────────────────────────────────────────────────────
create table circle (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references profile (id) on delete cascade,
  name         text not null check (char_length(name) between 1 and 40),
  slug         text not null check (slug ~ '^[a-z0-9_]{1,40}$'),
  is_system    boolean not null default false,   -- the built-in defaults
  is_public    boolean not null default false,   -- the special "Public" circle
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),
  unique (owner_id, slug)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- circle_member: who is in a circle. Membership is private to the owner.
-- ─────────────────────────────────────────────────────────────────────────────
create table circle_member (
  circle_id    uuid not null references circle (id) on delete cascade,
  member_id    uuid not null references profile (id) on delete cascade,
  added_at     timestamptz not null default now(),
  primary key (circle_id, member_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- follow: directed edge. follower follows followee.
-- ─────────────────────────────────────────────────────────────────────────────
create table follow (
  follower_id  uuid not null references profile (id) on delete cascade,
  followee_id  uuid not null references profile (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create index follow_followee_idx on follow (followee_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- block: hard block. Enforced in RLS across the schema.
-- ─────────────────────────────────────────────────────────────────────────────
create table block (
  blocker_id   uuid not null references profile (id) on delete cascade,
  blocked_id   uuid not null references profile (id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create index block_blocked_idx on block (blocked_id);

-- helper: is there a block in either direction between a and b?
create or replace function blocked_between(a uuid, b uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from block
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- when A blocks B, drop any follow edges between them
create or replace function drop_follows_on_block() returns trigger
language plpgsql as $$
begin
  delete from follow
   where (follower_id = new.blocker_id and followee_id = new.blocked_id)
      or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end;
$$;

create trigger block_drops_follows after insert on block
  for each row execute function drop_follows_on_block();

-- ─────────────────────────────────────────────────────────────────────────────
-- mute: soft. The muted account never knows. Optional expiry.
-- ─────────────────────────────────────────────────────────────────────────────
create table mute (
  muter_id     uuid not null references profile (id) on delete cascade,
  muted_id     uuid not null references profile (id) on delete cascade,
  expires_at   timestamptz,
  created_at   timestamptz not null default now(),
  primary key (muter_id, muted_id),
  check (muter_id <> muted_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- mute_word: keyword / hashtag muting across feed + notifications.
-- ─────────────────────────────────────────────────────────────────────────────
create table mute_word (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references profile (id) on delete cascade,
  phrase       text not null check (char_length(phrase) between 1 and 100),
  expires_at   timestamptz,
  created_at   timestamptz not null default now(),
  unique (owner_id, phrase)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- New-account bootstrap: profile + default persona + system circles.
-- Called by an Edge Function right after sign-up (needs the chosen handle),
-- so it is SECURITY DEFINER and validates the caller.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function bootstrap_account(p_handle citext, p_display_name text, p_kind account_kind default 'adult')
returns profile
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := auth.uid();
  v_profile profile;
begin
  if v_id is null then
    raise exception 'not authenticated';
  end if;
  if exists (select 1 from profile where id = v_id) then
    raise exception 'account already bootstrapped';
  end if;

  insert into profile (id, handle, display_name, account_kind)
  values (v_id, p_handle, coalesce(nullif(p_display_name, ''), p_handle::text), p_kind)
  returning * into v_profile;

  insert into persona (account_id, label, is_default) values (v_id, 'main', true);

  insert into circle (owner_id, name, slug, is_system, is_public, sort_order) values
    (v_id, 'Public',        'public',       true, true,  0),
    (v_id, 'Friends',       'friends',      true, false, 1),
    (v_id, 'Close Friends', 'close_friends',true, false, 2),
    (v_id, 'Family',        'family',       true, false, 3),
    (v_id, 'Work',          'work',         true, false, 4);

  return v_profile;
end;
$$;

revoke all on function bootstrap_account(citext, text, account_kind) from public;
grant execute on function bootstrap_account(citext, text, account_kind) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Row-Level Security
-- ─────────────────────────────────────────────────────────────────────────────
alter table profile        enable row level security;
alter table persona        enable row level security;
alter table circle         enable row level security;
alter table circle_member  enable row level security;
alter table follow         enable row level security;
alter table block          enable row level security;
alter table mute           enable row level security;
alter table mute_word      enable row level security;

-- profile: readable if not blocked in either direction; teen profiles only to
-- self and confirmed followers. Writable only by self.
create policy profile_select on profile for select using (
  not blocked_between(auth.uid(), id)
  and (
    id = auth.uid()
    or account_kind = 'adult'
    or exists (select 1 from follow f where f.follower_id = auth.uid() and f.followee_id = id)
  )
);
create policy profile_insert on profile for insert with check (id = auth.uid());
create policy profile_update on profile for update using (id = auth.uid()) with check (id = auth.uid());
create policy profile_delete on profile for delete using (id = auth.uid());

-- persona: owner-only for now
create policy persona_all on persona for all
  using (account_id = auth.uid()) with check (account_id = auth.uid());

-- circle + membership: strictly owner-only (audience is private)
create policy circle_all on circle for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy circle_member_all on circle_member for all
  using (exists (select 1 from circle c where c.id = circle_id and c.owner_id = auth.uid()))
  with check (exists (select 1 from circle c where c.id = circle_id and c.owner_id = auth.uid()));

-- follow: you can see edges you're part of; you create your own; no following
-- across a block; can't follow a non-discoverable teen you don't already know.
create policy follow_select on follow for select using (
  follower_id = auth.uid() or followee_id = auth.uid()
);
create policy follow_insert on follow for insert with check (
  follower_id = auth.uid()
  and not blocked_between(auth.uid(), followee_id)
  and exists (select 1 from profile p where p.id = followee_id)
);
create policy follow_delete on follow for delete using (follower_id = auth.uid());

-- block: private to the blocker
create policy block_all on block for all
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

-- mute + mute_word: private to the owner
create policy mute_all on mute for all
  using (muter_id = auth.uid()) with check (muter_id = auth.uid());
create policy mute_word_all on mute_word for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
