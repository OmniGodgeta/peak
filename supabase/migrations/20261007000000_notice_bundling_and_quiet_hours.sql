-- Bundle repeat likes into one unread notice, and let a person set quiet hours.
-- During quiet hours the row is stored with scheduled_at in the future.
-- The app must hide rows whose scheduled_at is still in the future.

alter table user_notification
  add column if not exists reaction_count int not null default 1;

alter table user_notification
  add column if not exists scheduled_at timestamptz;

create table if not exists user_settings (
  user_id uuid primary key references profile (id) on delete cascade,
  quiet_hours_start time,
  quiet_hours_end time
);

alter table user_settings enable row level security;

drop policy if exists user_settings_own on user_settings;
create policy user_settings_own on user_settings
  for all using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function notice_visible_at(p_user uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start time;
  v_end time;
  v_now time := localtime;
begin
  select quiet_hours_start, quiet_hours_end
    into v_start, v_end
  from user_settings
  where user_id = p_user;

  if v_start is null or v_end is null or v_start = v_end then
    return now();
  end if;

  if v_start < v_end then
    if v_now >= v_start and v_now < v_end then
      return date_trunc('day', now()) + v_end;
    end if;
  elsif v_now >= v_start or v_now < v_end then
    if v_now >= v_start then
      return date_trunc('day', now()) + interval '1 day' + v_end;
    end if;
    return date_trunc('day', now()) + v_end;
  end if;
  return now();
end;
$$;

create or replace function notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_when timestamptz;
begin
  select author_id into v_author from post where id = new.post_id;
  if v_author is null or v_author = new.actor_id then
    return new;
  end if;

  v_when := notice_visible_at(v_author);

  update user_notification
    set reaction_count = reaction_count + 1,
        actor_id = new.actor_id,
        created_at = now(),
        scheduled_at = case when v_when > now() then v_when else null end
    where recipient_id = v_author
      and kind = 'like'
      and post_id = new.post_id
      and read_at is null;

  if found then
    return new;
  end if;

  insert into user_notification (
    recipient_id, actor_id, kind, post_id, reaction_count, scheduled_at
  )
  values (
    v_author,
    new.actor_id,
    'like',
    new.post_id,
    1,
    case when v_when > now() then v_when else null end
  );
  return new;
end;
$$;

revoke all on function notice_visible_at(uuid) from public, anon, authenticated;
revoke all on function notify_on_reaction() from public, anon, authenticated;
