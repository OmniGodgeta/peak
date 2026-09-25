-- Live rooms: lists call_rooms tied to a Space that currently have at least
-- one active (not left) participant. call_rooms/call_participants already
-- existed (20261008210000_calls_and_rooms.sql) with no "is this room still
-- going" concept - this derives it from real participant rows instead of
-- adding an is_active flag that could drift out of sync.

create or replace function list_active_space_rooms(p_space_id uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  participant_count int
)
language sql
stable
as $$
  select
    cr.id,
    cr.title,
    cr.owner_id,
    count(cp.user_id)::int as participant_count
  from call_rooms cr
  join call_participants cp on cp.room_id = cr.id and cp.left_at is null
  where cr.space_id = p_space_id
  group by cr.id, cr.title, cr.owner_id
  having count(cp.user_id) > 0
  order by count(cp.user_id) desc;
$$;

revoke all on function list_active_space_rooms(uuid) from public;
grant execute on function list_active_space_rooms(uuid) to authenticated;
