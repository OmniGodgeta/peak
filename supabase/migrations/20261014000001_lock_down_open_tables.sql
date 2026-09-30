-- SECURITY: six public tables were created without row-level security, so
-- Supabase's default grants gave the anon key (shipped in every app build)
-- full SELECT/INSERT/UPDATE/DELETE/TRUNCATE on them:
--
--   account_exports        full user data exports + download tokens
--   fanout_feed_index      which posts are in whose feed (the follow graph,
--                          private post ids), and writable: feed injection
--   post_engagement_cache  per-post reaction counts (private by default)
--   system_config          incl. federation_enabled — anyone could turn
--                          federation on...
--   outbox_events          ...and then read every new post body queued
--                          here, private posts included (the outbox
--                          trigger ignored visibility)
--   inbox_activity_log
--
-- Checked on the hosted project 2026-09-30 (count-only): federation was off
-- and the outbox empty, so nothing had been queued there. Found while
-- auditing every public table for relrowsecurity.
--
-- Fix: RLS on everywhere, no direct access for anon/authenticated except a
-- user reading their own feed-index rows (feed_latest is SECURITY INVOKER
-- and reads it as the viewer). The trigger/helper functions that write
-- these tables as the acting user become SECURITY DEFINER, and the
-- federation outbox only ever queues public posts.

-- ── account_exports: only export_account() (definer) touches it ─────────
alter table account_exports enable row level security;
revoke all on account_exports from anon, authenticated;

-- ── fanout_feed_index: read your own rows; writes are definer/service ────
alter table fanout_feed_index enable row level security;
revoke all on fanout_feed_index from anon, authenticated;
grant select on fanout_feed_index to authenticated;
drop policy if exists fanout_feed_index_own on fanout_feed_index;
create policy fanout_feed_index_own on fanout_feed_index
  for select using (user_id = auth.uid());

-- ── post_engagement_cache: nothing reads it directly ─────────────────────
alter table post_engagement_cache enable row level security;
revoke all on post_engagement_cache from anon, authenticated;
alter function update_post_engagement_cache() security definer;
alter function update_post_engagement_cache() set search_path = public;
revoke all on function update_post_engagement_cache() from public, anon, authenticated;

-- ── federation tables ────────────────────────────────────────────────────
alter table system_config enable row level security;
alter table outbox_events enable row level security;
alter table inbox_activity_log enable row level security;
revoke all on system_config, outbox_events, inbox_activity_log from anon, authenticated;

-- Called from triggers as the acting user; they now read system_config /
-- write outbox_events with the owner's rights instead.
alter function is_federation_enabled() security definer;
alter function is_federation_enabled() set search_path = public;
revoke all on function is_federation_enabled() from public, anon, authenticated;

create or replace function trigger_outbox_post() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_follower record;
  v_payload jsonb;
begin
  -- Only public posts federate. Circle / followers-only / mention-only posts
  -- never leave the instance.
  if new.visibility <> 'public' or not is_federation_enabled() then
    return new;
  end if;
  for v_follower in
    select p.actor_url
    from follow f
    join profile p on p.id = f.follower_id
    where f.followee_id = new.author_id and p.actor_url is not null
  loop
    v_payload := jsonb_build_object(
      'type', case when new.reply_to is not null then 'reply' else 'post' end,
      'id', new.id,
      'actor', (select actor_url from profile where id = new.author_id),
      'content', new.body,
      'published', new.created_at
    );
    insert into outbox_events (type, target_url, payload)
    values (case when new.reply_to is not null then 'reply' else 'post' end,
            v_follower.actor_url, v_payload);
  end loop;
  return new;
end;
$$;

create or replace function trigger_outbox_reaction() returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_follower record;
begin
  if not is_federation_enabled()
     or not exists (select 1 from post where id = new.post_id and visibility = 'public') then
    return new;
  end if;
  for v_follower in
    select p.actor_url
    from follow f
    join profile p on p.id = f.follower_id
    where f.followee_id = (select author_id from post where id = new.post_id)
      and p.actor_url is not null
  loop
    insert into outbox_events (type, target_url, payload)
    values ('like', v_follower.actor_url, jsonb_build_object(
      'type', 'like',
      'id', gen_random_uuid(),
      'actor', (select actor_url from profile where id = new.actor_id),
      'object', new.post_id
    ));
  end loop;
  return new;
end;
$$;

revoke all on function trigger_outbox_post() from public, anon, authenticated;
revoke all on function trigger_outbox_reaction() from public, anon, authenticated;

-- Anything already queued from a non-public post is a leak waiting to be
-- sent; drop it.
delete from outbox_events o
using post p
where p.id::text = o.payload ->> 'id' and p.visibility <> 'public';

-- defence in depth: the queue already had no grants
alter table media_pending_delete enable row level security;

-- ── export_account: SECURITY DEFINER with no caller check, executable by
-- anon — anyone could pass any user's id and get their profile, every post
-- (private ones included), follows and likes. Only your own account now,
-- and only signed in. (The app's export uses the `export` Edge Function;
-- nothing called this.)
create or replace function export_account(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data jsonb;
  v_expiry timestamptz := now() + interval '30 days';
begin
  if auth.uid() is null or p_user_id is distinct from auth.uid() then
    raise exception 'you can only export your own account' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'profile', (select to_jsonb(p) from profile p where p.id = p_user_id),
    'posts', (select jsonb_agg(to_jsonb(po)) from post po where po.author_id = p_user_id),
    'follows', (select jsonb_agg(to_jsonb(f)) from follow f where f.follower_id = p_user_id),
    'likes', (select jsonb_agg(to_jsonb(l)) from reaction l where l.actor_id = p_user_id and l.kind = 'like')
  ) into v_data;

  insert into account_exports (user_id, data, expires_at, token)
  values (p_user_id, v_data, v_expiry, encode(extensions.gen_random_bytes(32), 'hex'));

  return (select to_jsonb(e) from account_exports e
          where e.user_id = p_user_id order by exported_at desc limit 1);
end;
$$;
revoke all on function export_account(uuid) from public, anon, authenticated;
grant execute on function export_account(uuid) to authenticated;

-- ── purge_expired_messages: a sweep for pg_cron, not for callers ─────────
revoke all on function purge_expired_messages() from public, anon, authenticated;
