create or replace function set_harassment_shield(p_duration_minutes int default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update profile
  set harassment_shield_expires_at = case
    when p_duration_minutes is null then now() + interval '100 years'
    else now() + (p_duration_minutes || ' minutes')::interval
  end
  where id = auth.uid();
end;
$$;

create or replace function clear_harassment_shield()
returns void
language plpgsql security definer set search_path = public as $$
begin
  update profile set harassment_shield_expires_at = null where id = auth.uid();
end;
$$;

grant execute on function set_harassment_shield(int) to authenticated;
grant execute on function clear_harassment_shield() to authenticated;
