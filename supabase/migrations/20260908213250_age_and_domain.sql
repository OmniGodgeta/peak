-- Peak — age gate (13+, self-declared) and federation-shaped handles.
--
-- Decisions (2026-09-08):
--  * Minimum age 13, self-declared at sign-up via date of birth.
--  * Under-18 accounts are teen accounts (private + non-discoverable defaults).
--  * Handles are addressed as @name@domain from day one; one instance for now
--    (peak.social), so the migration to real federation (Phase 7) is painless.

-- ── Handle domain ────────────────────────────────────────────────────────────
alter table profile
  add column domain text not null default 'peak.social'
    check (domain ~ '^[a-z0-9.-]{1,253}$');

comment on column profile.domain is
  'The instance this account lives on. Display handles as @handle@domain.';

create or replace function fq_handle(p profile) returns text
language sql immutable as $$
  select '@' || p.handle || '@' || p.domain;
$$;

-- ── Private per-account data: date of birth lives here, self-only ────────────
create table profile_private (
  id            uuid primary key references profile (id) on delete cascade,
  birthdate     date not null check (birthdate <= current_date),
  age_verified  boolean not null default false,   -- Phase 5: real age check
  updated_at    timestamptz not null default now()
);

alter table profile_private enable row level security;

create policy profile_private_self on profile_private for all
  using (id = auth.uid()) with check (id = auth.uid());

create trigger profile_private_updated_at before update on profile_private
  for each row execute function set_updated_at();

-- ── account_kind is derived from age, never trusted from the client ──────────
create or replace function kind_for_birthdate(p_birthdate date) returns account_kind
language sql stable as $$
  select case
    when p_birthdate > (current_date - interval '18 years')
      then 'teen'::account_kind
    else 'adult'::account_kind
  end;
$$;

-- keep profile.account_kind in step with profile_private.birthdate
create or replace function sync_account_kind() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profile
     set account_kind = kind_for_birthdate(new.birthdate)
   where id = new.id;
  return new;
end;
$$;

create trigger profile_private_syncs_kind
  after insert or update of birthdate on profile_private
  for each row execute function sync_account_kind();

-- ── bootstrap_account: takes a birthdate, enforces the 13+ floor ─────────────
drop function if exists bootstrap_account(citext, text, account_kind);

create or replace function bootstrap_account(
  p_handle citext,
  p_display_name text,
  p_birthdate date
)
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
  if p_birthdate is null then
    raise exception 'date of birth is required';
  end if;
  if p_birthdate > (current_date - interval '13 years') then
    raise exception 'you must be at least 13 to use Peak';
  end if;

  insert into profile (id, handle, display_name, account_kind)
  values (
    v_id,
    p_handle,
    coalesce(nullif(p_display_name, ''), p_handle::text),
    kind_for_birthdate(p_birthdate)
  )
  returning * into v_profile;

  insert into profile_private (id, birthdate) values (v_id, p_birthdate);

  insert into persona (account_id, label, is_default) values (v_id, 'main', true);

  insert into circle (owner_id, name, slug, is_system, is_public, sort_order) values
    (v_id, 'Public',        'public',        true, true,  0),
    (v_id, 'Friends',       'friends',       true, false, 1),
    (v_id, 'Close Friends', 'close_friends', true, false, 2),
    (v_id, 'Family',        'family',        true, false, 3),
    (v_id, 'Work',          'work',          true, false, 4);

  return v_profile;
end;
$$;

revoke all on function bootstrap_account(citext, text, date) from public;
grant execute on function bootstrap_account(citext, text, date) to authenticated;
