-- Peak — Phase 3: account deletion (PRODUCT.md §9.2).
--
-- Model: request → immediate suspend → 30-day grace (sign back in to cancel)
-- → purge. Requesting sets `deletion_requested_at`; the app then bounces the
-- user to a "closing" screen and hides them from discovery. After 30 days
-- `purge_due_accounts()` (cron) deletes the auth.users row, which cascades the
-- profile and everything it owns.
--
-- Not in this migration: hiding a closing account's *existing* posts from
-- followers' feeds mid-grace. That's the same "soft-hide an account" primitive
-- a moderation suspension needs (Phase 5); until then a closing account's
-- profile is unreachable but its old posts linger for the grace window.

alter table profile add column deletion_requested_at timestamptz;

comment on column profile.deletion_requested_at is
  'Set when the owner asks to delete the account. Cleared by cancel. '
  'purge_due_accounts() removes the account 30 days after this.';

-- ── request / cancel ──────────────────────────────────────────────────────
create or replace function request_account_deletion()
returns void
language plpgsql security invoker set search_path = public as $$
begin
  update profile
    set deletion_requested_at = coalesce(deletion_requested_at, now()),
        is_discoverable = false
    where id = auth.uid();
end;
$$;

create or replace function cancel_account_deletion()
returns void
language plpgsql security invoker set search_path = public as $$
begin
  update profile set deletion_requested_at = null
  where id = auth.uid();
end;
$$;

revoke all on function request_account_deletion() from public;
revoke all on function cancel_account_deletion()  from public;
grant execute on function request_account_deletion() to authenticated;
grant execute on function cancel_account_deletion()  to authenticated;

-- ── purge (cron) ──────────────────────────────────────────────────────────
-- Delete every account whose grace window has elapsed. Returns how many went.
-- Deleting auth.users cascades to profile → posts, follows, messages, devices…
create or replace function purge_due_accounts()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  with due as (
    delete from auth.users u
    using profile p
    where p.id = u.id
      and p.deletion_requested_at is not null
      and p.deletion_requested_at < now() - interval '30 days'
    returning 1
  )
  select count(*) into v_n from due;
  return v_n;
end;
$$;

-- ── hide a closing account from discovery ─────────────────────────────────
create or replace function search_people(q text, p_limit int default 20)
returns table (
  id uuid,
  handle citext,
  domain text,
  display_name text,
  bio text,
  avatar_path text,
  is_teen boolean,
  is_following boolean
)
language sql stable as $$
  select
    p.id, p.handle, p.domain, p.display_name, p.bio, p.avatar_path,
    (p.account_kind = 'teen'),
    exists (select 1 from follow f
            where f.follower_id = auth.uid() and f.followee_id = p.id)
  from profile p
  where p.id <> auth.uid()
    and p.deletion_requested_at is null
    and not blocked_between(auth.uid(), p.id)
    and (
      p.is_discoverable
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.id)
    )
    and (
      length(trim(q)) >= 2
      and (
        p.handle ilike trim(q) || '%'
        or p.display_name ilike '%' || trim(q) || '%'
      )
    )
  order by
    (p.handle ilike trim(q) || '%') desc,
    p.handle
  limit least(p_limit, 50);
$$;

create or replace function profile_view(p_handle citext, p_domain text default 'peak.social')
returns table (
  id uuid,
  handle citext,
  domain text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  pronouns text,
  location_coarse text,
  links jsonb,
  is_teen boolean,
  created_at timestamptz,
  is_self boolean,
  is_following boolean,
  follows_you boolean,
  show_follow_counts boolean,
  follower_count bigint,
  following_count bigint,
  post_count bigint
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
    (select count(*) from post po where po.author_id = p.id and po.deleted_at is null and po.reply_to is null)
  from profile p
  where p.handle = p_handle and p.domain = p_domain
    and (p.deletion_requested_at is null or p.id = auth.uid())
    and not blocked_between(auth.uid(), p.id);
$$;
