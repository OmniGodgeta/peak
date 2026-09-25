create or replace function set_mute(p_target uuid, p_duration_minutes int default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_target = auth.uid() then
    raise exception 'cannot mute yourself';
  end if;
  insert into mute (muter_id, muted_id, expires_at)
  values (
    auth.uid(),
    p_target,
    case when p_duration_minutes is null then null
         else now() + (p_duration_minutes || ' minutes')::interval end
  )
  on conflict (muter_id, muted_id) do update
    set expires_at = excluded.expires_at, created_at = now();
end;
$$;

create or replace function clear_mute(p_target uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from mute where muter_id = auth.uid() and muted_id = p_target;
end;
$$;

grant execute on function set_mute(uuid, int) to authenticated;
grant execute on function clear_mute(uuid) to authenticated;