create table video_subscription (
  subscriber_id uuid not null references profile(id) on delete cascade,
  creator_id    uuid not null references profile(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (subscriber_id, creator_id),
  check (subscriber_id <> creator_id)
);

alter table video_subscription enable row level security;

create policy "subscriptions are publicly countable"
  on video_subscription for select using (true);

create policy "users manage their own subscriptions"
  on video_subscription for all
  using (subscriber_id = auth.uid())
  with check (subscriber_id = auth.uid());

-- Mirrors the existing toggle_reaction/toggle_repost idiom in
-- 20260908224511_feed_with_author.sql - do not hand-roll insert/delete
-- from the client.
create or replace function toggle_video_subscription(p_creator_id uuid)
returns boolean -- true = now subscribed, false = unsubscribed
language plpgsql as $$
begin
  if p_creator_id = auth.uid() then
    raise exception 'cannot subscribe to yourself';
  end if;
  if exists (select 1 from video_subscription where subscriber_id = auth.uid() and creator_id = p_creator_id) then
    delete from video_subscription where subscriber_id = auth.uid() and creator_id = p_creator_id;
    return false;
  end if;
  insert into video_subscription (subscriber_id, creator_id) values (auth.uid(), p_creator_id);
  return true;
end;
$$;

create or replace function channel_subscriber_count(p_creator_id uuid)
returns int language sql stable as $$
  select count(*)::int from video_subscription where creator_id = p_creator_id;
$$;

create or replace function is_subscribed_to_channel(p_creator_id uuid)
returns boolean language sql stable as $$
  select exists (
    select 1 from video_subscription
    where subscriber_id = auth.uid() and creator_id = p_creator_id
  );
$$;
