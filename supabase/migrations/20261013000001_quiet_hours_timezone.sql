-- Quiet hours were never actually applied server-side:
--   1. the app kept quiet hours on the device only and never wrote
--      user_settings, so notice_visible_at() always returned now();
--   2. notice_visible_at() compared against the database's localtime, which
--      is UTC on Supabase, so 22:00-07:00 would have meant 22:00-07:00 UTC.
-- Now the app syncs its quiet hours plus the device's UTC offset (re-synced
-- on each launch, which also covers daylight-saving changes), and the
-- window is evaluated on the user's own clock. Push delivery and in-app
-- notice scheduling both go through notice_visible_at(), so both respect it.

alter table user_settings
  add column if not exists utc_offset_minutes int not null default 0
    check (utc_offset_minutes between -840 and 840);

create or replace function set_my_quiet_hours(
  p_start time, p_end time, p_utc_offset_minutes int
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  insert into user_settings (user_id, quiet_hours_start, quiet_hours_end, utc_offset_minutes)
  values (auth.uid(), p_start, p_end, coalesce(p_utc_offset_minutes, 0))
  on conflict (user_id) do update
    set quiet_hours_start = excluded.quiet_hours_start,
        quiet_hours_end = excluded.quiet_hours_end,
        utc_offset_minutes = excluded.utc_offset_minutes;
end;
$$;

create or replace function notice_visible_at(p_user uuid)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_start time;
  v_end   time;
  v_off   interval;
  v_local timestamp;  -- the user's wall clock right now
  v_now   time;
  v_until timestamp;  -- end of quiet hours, on the user's wall clock
begin
  select quiet_hours_start, quiet_hours_end, make_interval(mins => utc_offset_minutes)
    into v_start, v_end, v_off
  from user_settings
  where user_id = p_user;

  if v_start is null or v_end is null or v_start = v_end then
    return now();
  end if;

  v_local := (now() at time zone 'UTC') + v_off;
  v_now := v_local::time;

  if v_start < v_end then
    -- same-day window, e.g. 13:00-15:00
    if v_now >= v_start and v_now < v_end then
      v_until := date_trunc('day', v_local) + v_end;
    end if;
  elsif v_now >= v_start then
    -- overnight window, before midnight: ends tomorrow
    v_until := date_trunc('day', v_local) + interval '1 day' + v_end;
  elsif v_now < v_end then
    -- overnight window, after midnight: ends today
    v_until := date_trunc('day', v_local) + v_end;
  end if;

  if v_until is null then
    return now();
  end if;
  return (v_until - v_off) at time zone 'UTC';
end;
$$;

revoke all on function set_my_quiet_hours(time, time, int) from public, anon, authenticated;
grant execute on function set_my_quiet_hours(time, time, int) to authenticated;
revoke all on function notice_visible_at(uuid) from public, anon, authenticated;
