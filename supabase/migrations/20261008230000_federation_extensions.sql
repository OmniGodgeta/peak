-- federation_extensions.sql
-- Adds support for ActivityPub by extending profiles and adding outbox triggers.

-- 1. Extend Profile to include Actor information
alter table profile add column if not exists actor_url text unique;

-- 2. Helper function to check if federation is enabled
create or replace function is_federation_enabled() returns boolean as $$
declare
  v_enabled boolean;
begin
  select (value = 'true') into v_enabled from system_config where key = 'federation_enabled';
  return coalesce(v_enabled, false);
end;
$$ language plpgsql stable;

-- 3. Outbox Trigger Logic
-- We want to queue an event whenever a post or reaction occurs IF federation is on.

create type outbox_event_data as (
  activity_type text,
  target_uri text,
  payload jsonb
);

-- Trigger function for posts
create or replace function trigger_outbox_post() returns trigger as $$
declare
  v_follower record;
  v_payload jsonb;
begin
  if is_federation_enabled() then
    -- For every follower of the author, find their remote inbox URL
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
        'object', CASE WHEN new.reply_to IS NOT NULL THEN (select actor_url from profile where id = new.reply_to) ELSE null END,
        'content', new.body,
        'published', new.created_at
      );

      insert into outbox_events (type, target_url, payload)
      values (case when new.reply_to is not null then 'reply'::text else 'post'::text end, v_follower.actor_url, v_payload);
    end loop;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger post_federation_outbox
after insert on post
for each row execute function trigger_outbox_post();

-- Trigger for reactions (likes/etc)
create or replace function trigger_outbox_reaction() returns trigger as $$
declare
  v_follower record;
  v_payload jsonb;
begin
  if is_federation_enabled() then
     for v_follower in 
      select p.actor_url 
      from follow f
      join profile p on p.id = f.follower_id
      where f.followee_id = (select author_id from post where id = new.post_id) and p.actor_url is not null
    loop
      v_payload := jsonb_build_object(
        'type', 'like',
        'id', gen_random_uuid(), -- ActivityPub likes often have their own ID
        'actor', (select actor_url from profile where id = new.actor_id),
        'object', (select actor_url from profile where id = (select author_id from post where id = new.post_id)),
        'target', new.kind
      );

      insert into outbox_events (type, target_url, payload)
      values ('like', v_follower.actor_url, v_payload);
    end loop;
  end if;
  return new;
end;
$$ language plpgsql;

create trigger reaction_federation_outbox
after insert on reaction
for each row execute function trigger_outbox_reaction();
