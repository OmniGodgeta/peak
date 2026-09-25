-- federation_setup.sql

-- 1. System configuration for toggling features
create table if not exists system_config (
  key text primary key,
  value text not null
);

insert into system_config (key, value) values ('federation_enabled', 'false')
on conflict (key) do nothing;

-- 2. Outbox for reliable delivery of ActivityPub activities
create table if not exists outbox_events (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('follow', 'post', 'reply', 'like')),
  target_url text not null,
  payload jsonb not null,
  status text not null default 'pending' check (status in ('pending', 'delivered', 'failed')),
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index outbox_events_status_idx on outbox_events (status) where status = 'pending';

-- 3. Inbox log to prevent duplicate processing (Idempotency)
create table if not exists inbox_activity_log (
  id uuid primary key default gen_random_uuid(),
  remote_actor_id text not null, -- The URI or username from the remote server
  activity_id text not null,     -- The ID from the Activity JSON
  type text not null,
  received_at timestamptz not null default now(),
  unique(remote_actor_id, activity_id)
);

-- Trigger to update updated_at
create or replace function update_timestamp() returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger outbox_events_updated_at before update on outbox_events
for each row execute function update_timestamp();
