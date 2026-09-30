-- Push notifications over UnifiedPush / Web Push. No Google, no Firebase.
--
-- A device registers the endpoint its distributor (ntfy, NextPush, ...) gave
-- it, plus the RFC 8291 keys to encrypt for it. Events land in push_queue:
--   * a new in-app notice (like / reply / follow), deferred to the end of the
--     recipient's quiet hours exactly like the notice itself;
--   * a new DM, for every other active member who hasn't muted the chat.
-- The push-dispatch Edge Function (pg_cron, every minute) claims due rows,
-- bundles them per person, encrypts and sends. Payloads are encrypted end to
-- end to the device, so the distributor only sees ciphertext.
--
-- Calls don't wait for cron: the caller's app asks push-dispatch to ring,
-- and call_ring_targets() checks the caller really owns a fresh room and is
-- in the conversation before anyone is rung.

create table push_subscription (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references profile (id) on delete cascade,
  endpoint    text not null unique
                check (endpoint like 'https://%' and char_length(endpoint) <= 2048),
  p256dh      text not null check (p256dh ~ '^[A-Za-z0-9_-]{87}$'),
  auth        text not null check (auth ~ '^[A-Za-z0-9_-]{22}$'),
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  failures    int not null default 0
);
create index push_subscription_profile_idx on push_subscription (profile_id);

alter table push_subscription enable row level security;
create policy push_subscription_own_select on push_subscription
  for select using (profile_id = auth.uid());
create policy push_subscription_own_delete on push_subscription
  for delete using (profile_id = auth.uid());

-- Registering moves an endpoint to whoever is signed in on that device now
-- (a shared phone that switched accounts).
create or replace function register_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  insert into push_subscription (profile_id, endpoint, p256dh, auth)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set profile_id = excluded.profile_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        failures = 0;
end;
$$;

create or replace function unregister_push_subscription(p_endpoint text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from push_subscription
  where endpoint = p_endpoint and profile_id = auth.uid();
$$;

create table push_queue (
  id            bigserial primary key,
  recipient_id  uuid not null references profile (id) on delete cascade,
  kind          text not null check (kind in ('like', 'reply', 'follow', 'message')),
  actor_id      uuid references profile (id) on delete set null,
  ref_id        uuid,
  deliver_after timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index push_queue_due_idx on push_queue (deliver_after) where sent_at is null;

alter table push_queue enable row level security;
-- No policies: only the service role (push-dispatch) touches the queue.

create or replace function queue_push_for_notice()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from push_subscription where profile_id = new.recipient_id) then
    insert into push_queue (recipient_id, kind, actor_id, ref_id, deliver_after)
    values (new.recipient_id, new.kind, new.actor_id, new.post_id,
            coalesce(new.scheduled_at, now()));
  end if;
  return new;
end;
$$;

drop trigger if exists user_notification_push on user_notification;
create trigger user_notification_push
  after insert on user_notification
  for each row execute function queue_push_for_notice();

create or replace function queue_push_for_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into push_queue (recipient_id, kind, actor_id, ref_id, deliver_after)
  select m.member_id, 'message', new.sender_id, new.conversation_id,
         notice_visible_at(m.member_id)
  from conversation_member m
  where m.conversation_id = new.conversation_id
    and m.member_id <> new.sender_id
    and m.state = 'active'
    and not coalesce(m.notifications_muted, false)
    and not blocked_between(m.member_id, new.sender_id)
    and exists (select 1 from push_subscription s where s.profile_id = m.member_id);
  return new;
end;
$$;

drop trigger if exists message_push on message;
create trigger message_push
  after insert on message
  for each row execute function queue_push_for_message();

-- Claims due rows (marks them sent) and returns one bundle per recipient:
-- how many, the newest kind/actor/ref, and the kinds involved. Old sent rows
-- are pruned on the way.
create or replace function claim_push_batch(p_limit int default 500)
returns table (
  recipient_id uuid,
  n            int,
  kinds        text[],
  last_kind    text,
  last_actor   text,
  last_ref     uuid
)
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from push_queue q where q.sent_at < now() - interval '7 days';
  -- Anything a day late isn't worth a buzz any more.
  update push_queue q set sent_at = now()
  where q.sent_at is null and q.created_at < now() - interval '1 day';

  return query
  with due as (
    select q.id
    from push_queue q
    where q.sent_at is null and q.deliver_after <= now()
    order by q.id
    limit p_limit
    for update skip locked
  ), claimed as (
    update push_queue q set sent_at = now()
    from due where q.id = due.id
    returning q.*
  )
  select c.recipient_id,
         count(*)::int,
         array_agg(distinct c.kind),
         (array_agg(c.kind order by c.id desc))[1],
         (array_agg(coalesce(nullif(p.display_name, ''), p.handle::text)
                    order by c.id desc))[1],
         (array_agg(c.ref_id order by c.id desc))[1]
  from claimed c
  left join profile p on p.id = c.actor_id
  group by c.recipient_id;
end;
$$;

-- Who to ring for a call the signed-in user just started from a DM.
create or replace function call_ring_targets(p_room uuid, p_conversation uuid)
returns table (recipient_id uuid, caller_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  if not exists (
    select 1 from call_rooms r
    where r.id = p_room and r.owner_id = v_me
      and r.created_at > now() - interval '2 minutes'
  ) then
    raise exception 'not your call' using errcode = '42501';
  end if;
  if not exists (
    select 1 from conversation_member m
    where m.conversation_id = p_conversation and m.member_id = v_me
      and m.state = 'active'
  ) then
    raise exception 'not in that conversation' using errcode = '42501';
  end if;

  return query
  select m.member_id,
         (select coalesce(nullif(p.display_name, ''), p.handle::text)
          from profile p where p.id = v_me)
  from conversation_member m
  where m.conversation_id = p_conversation
    and m.member_id <> v_me
    and m.state = 'active'
    and not coalesce(m.notifications_muted, false)
    and not blocked_between(m.member_id, v_me);
end;
$$;

revoke all on function register_push_subscription(text, text, text) from public, anon, authenticated;
revoke all on function unregister_push_subscription(text) from public, anon, authenticated;
revoke all on function queue_push_for_notice() from public, anon, authenticated;
revoke all on function queue_push_for_message() from public, anon, authenticated;
revoke all on function claim_push_batch(int) from public, anon, authenticated;
revoke all on function call_ring_targets(uuid, uuid) from public, anon, authenticated;
grant execute on function register_push_subscription(text, text, text) to authenticated;
grant execute on function unregister_push_subscription(text) to authenticated;
grant execute on function call_ring_targets(uuid, uuid) to authenticated;
grant execute on function claim_push_batch(int) to service_role;
