-- Peak — Phase 5: proof-of-personhood.
--
-- A lightweight "this is a real person" signal, deliberately not identity
-- verification. Two ways in:
--   • staff grant — an operator marks an account
--   • peer vouch — 3 already-verified people vouch for you and you're in
-- Losing vouches below the threshold drops a vouch-based badge (a staff grant
-- sticks). The badge is public; who vouched for whom is not.

create type personhood_method as enum ('staff', 'vouch');

create table personhood (
  profile_id uuid primary key references profile (id) on delete cascade,
  method     personhood_method not null,
  granted_by uuid references profile (id) on delete set null,
  granted_at timestamptz not null default now()
);

create table personhood_vouch (
  voucher_id uuid not null references profile (id) on delete cascade,
  subject_id uuid not null references profile (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (voucher_id, subject_id),
  check (voucher_id <> subject_id)
);
create index personhood_vouch_subject on personhood_vouch (subject_id);

alter table personhood       enable row level security;
alter table personhood_vouch enable row level security;

-- the badge itself is public; all writes go through the RPCs below
create policy personhood_read on personhood for select using (true);
-- a vouch is visible only to the two parties
create policy vouch_read on personhood_vouch for select
  using (voucher_id = auth.uid() or subject_id = auth.uid());

create or replace function is_verified_person(p_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from personhood where profile_id = p_id);
$$;

-- total vouches for an account (personhood_vouch RLS hides rows the caller
-- isn't party to, so profile_view can't count them directly)
create or replace function vouch_count_for(p_id uuid)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from personhood_vouch where subject_id = p_id;
$$;

-- how many vouches, and did the caller cast one
create or replace function personhood_of(p_handle citext)
returns table (
  verified boolean, method text, vouch_count int, i_vouched boolean
)
language sql stable security definer set search_path = public as $$
  select
    exists (select 1 from personhood ph where ph.profile_id = p.id),
    (select ph.method::text from personhood ph where ph.profile_id = p.id),
    (select count(*)::int from personhood_vouch v where v.subject_id = p.id),
    exists (select 1 from personhood_vouch v
            where v.subject_id = p.id and v.voucher_id = auth.uid())
  from profile p
  where p.handle = p_handle and p.domain = 'peak.social';
$$;

create or replace function vouch_for(p_handle citext)
returns void
language plpgsql security definer set search_path = public as $$
declare v_subject uuid; v_count int;
begin
  if not is_verified_person(auth.uid()) then
    raise exception 'only verified people can vouch';
  end if;
  select id into v_subject from profile
  where handle = p_handle and domain = 'peak.social';
  if v_subject is null then raise exception 'no such person'; end if;
  if v_subject = auth.uid() then raise exception 'cannot vouch for yourself'; end if;

  insert into personhood_vouch (voucher_id, subject_id)
  values (auth.uid(), v_subject) on conflict do nothing;

  select count(*) into v_count from personhood_vouch where subject_id = v_subject;
  if v_count >= 3 and not exists (
    select 1 from personhood where profile_id = v_subject
  ) then
    insert into personhood (profile_id, method) values (v_subject, 'vouch');
  end if;
end;
$$;

create or replace function unvouch(p_handle citext)
returns void
language plpgsql security definer set search_path = public as $$
declare v_subject uuid; v_count int;
begin
  select id into v_subject from profile
  where handle = p_handle and domain = 'peak.social';
  if v_subject is null then raise exception 'no such person'; end if;

  delete from personhood_vouch
  where voucher_id = auth.uid() and subject_id = v_subject;

  select count(*) into v_count from personhood_vouch where subject_id = v_subject;
  if v_count < 3 then
    delete from personhood
    where profile_id = v_subject and method = 'vouch';
  end if;
end;
$$;

-- people I've vouched for
create or replace function my_vouches()
returns table (handle citext, display_name text, verified boolean)
language sql stable security definer set search_path = public as $$
  select p.handle, p.display_name,
         exists (select 1 from personhood ph where ph.profile_id = p.id)
  from personhood_vouch v
  join profile p on p.id = v.subject_id
  where v.voucher_id = auth.uid()
  order by p.handle;
$$;

-- ── staff ─────────────────────────────────────────────────────────────
create or replace function grant_personhood(p_handle citext)
returns void
language plpgsql security definer set search_path = public as $$
declare v_subject uuid;
begin
  if not is_staff(auth.uid()) then raise exception 'staff only'; end if;
  select id into v_subject from profile
  where handle = p_handle and domain = 'peak.social';
  if v_subject is null then raise exception 'no such person'; end if;
  insert into personhood (profile_id, method, granted_by)
  values (v_subject, 'staff', auth.uid())
  on conflict (profile_id) do update
    set method = 'staff', granted_by = auth.uid(), granted_at = now();
end;
$$;

create or replace function revoke_personhood(p_handle citext)
returns void
language plpgsql security definer set search_path = public as $$
declare v_subject uuid;
begin
  if not is_staff(auth.uid()) then raise exception 'staff only'; end if;
  select id into v_subject from profile
  where handle = p_handle and domain = 'peak.social';
  if v_subject is null then raise exception 'no such person'; end if;
  delete from personhood where profile_id = v_subject;
end;
$$;

-- accounts partway to the vouch threshold, for a staff review screen
create or replace function personhood_pending(p_limit int default 50)
returns table (handle citext, display_name text, vouch_count int)
language sql stable security definer set search_path = public as $$
  select p.handle, p.display_name, count(*)::int
  from personhood_vouch v
  join profile p on p.id = v.subject_id
  where not exists (select 1 from personhood ph where ph.profile_id = p.id)
    and is_staff(auth.uid())
  group by p.handle, p.display_name
  order by count(*) desc
  limit least(p_limit, 200);
$$;

-- ── profile_view gains the badge ──────────────────────────────────────
drop function if exists profile_view(citext, text);
create or replace function profile_view(
  p_handle citext, p_domain text default 'peak.social'
)
returns table (
  id uuid, handle citext, domain text, display_name text, bio text,
  avatar_path text, banner_path text, pronouns text, location_coarse text,
  links jsonb, is_teen boolean, created_at timestamptz, is_self boolean,
  is_following boolean, follows_you boolean, show_follow_counts boolean,
  follower_count bigint, following_count bigint, post_count bigint,
  is_verified_person boolean, personhood_method text, vouch_count int
)
language sql stable as $$
  select
    p.id, p.handle, p.domain, p.display_name, p.bio, p.avatar_path,
    p.banner_path, p.pronouns, p.location_coarse, p.links,
    (p.account_kind = 'teen'),
    p.created_at,
    (p.id = auth.uid()),
    exists (select 1 from follow f where f.follower_id = auth.uid() and f.followee_id = p.id),
    exists (select 1 from follow f where f.follower_id = p.id and f.followee_id = auth.uid()),
    p.show_follow_counts,
    (select count(*) from follow f where f.followee_id = p.id),
    (select count(*) from follow f where f.follower_id = p.id),
    (select count(*) from post po where po.author_id = p.id and po.deleted_at is null and po.reply_to is null),
    exists (select 1 from personhood ph where ph.profile_id = p.id),
    (select ph.method::text from personhood ph where ph.profile_id = p.id),
    vouch_count_for(p.id)
  from profile p
  where p.handle = p_handle and p.domain = p_domain
    and (p.deletion_requested_at is null or p.id = auth.uid())
    and not blocked_between(auth.uid(), p.id);
$$;

grant execute on function profile_view(citext, text)     to authenticated, anon;
grant execute on function is_verified_person(uuid)       to authenticated, anon;
grant execute on function vouch_count_for(uuid)          to authenticated, anon;

revoke all on function personhood_of(citext)        from public, anon;
revoke all on function vouch_for(citext)            from public, anon;
revoke all on function unvouch(citext)              from public, anon;
revoke all on function my_vouches()                 from public, anon;
revoke all on function grant_personhood(citext)     from public, anon;
revoke all on function revoke_personhood(citext)    from public, anon;
revoke all on function personhood_pending(int)      from public, anon;
grant execute on function personhood_of(citext)      to authenticated;
grant execute on function vouch_for(citext)          to authenticated;
grant execute on function unvouch(citext)            to authenticated;
grant execute on function my_vouches()               to authenticated;
grant execute on function grant_personhood(citext)   to authenticated;
grant execute on function revoke_personhood(citext)  to authenticated;
grant execute on function personhood_pending(int)    to authenticated;
