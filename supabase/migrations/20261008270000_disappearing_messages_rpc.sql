create or replace function set_disappearing_messages(p_conversation uuid, p_enabled boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_conversation_member(p_conversation, auth.uid()) then
    raise exception 'not a member';
  end if;
  update conversation set disappearing_enabled = p_enabled where id = p_conversation;
end;
$$;

grant execute on function set_disappearing_messages(uuid, boolean) to authenticated;

-- Storage hygiene only (reads are already blocked by RLS above): hard-delete
-- rows that have been expired a while, mirroring purge_expired_stories()'s
-- existing pattern in this schema.
create or replace function purge_expired_messages() returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from message where expires_at is not null and expires_at < now() - interval '1 day';
end;
$$;
