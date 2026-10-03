-- E2EE stage 2.5-4: membership and device changes in encrypted conversations
-- (docs/ENCRYPTION.md). Members' devices add newly registered devices, add
-- new group members, and remove devices of people who left or devices that
-- were revoked, each change being one MLS Commit.
--
-- Two devices committing at the same epoch would fork the group, so commits
-- only go through publish_mls_commit, which accepts one only if the group is
-- still at the epoch it was made from (compare-and-swap on
-- mls_group_state.epoch). The loser reloads, catches up and retries.

-- Commits (and the group state) can no longer be written directly; only
-- Welcomes for the initial setup still are.
drop policy if exists mls_group_state_write on mls_group_state;

drop policy if exists mls_message_insert on mls_message;
create policy mls_message_insert on mls_message for insert with check (
  content_type = 'welcome'
  and is_conversation_member(conversation_id, auth.uid())
  and exists (select 1 from device d
              where d.id = sender_device_id and d.account_id = auth.uid())
);

-- One KeyPackage for each listed device (not every device of an account).
create or replace function claim_device_key_packages(p_devices uuid[])
returns table (out_device_id uuid, out_account_id uuid, out_key_package bytea)
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  r record;
  v_pkg uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  for r in
    select d.id, d.account_id from device d
    where d.id = any (p_devices) and d.revoked_at is null
      and not blocked_between(v_me, d.account_id)
  loop
    select kp.id into v_pkg from key_package kp
     where kp.device_id = r.id and kp.consumed_at is null
     order by kp.created_at limit 1
     for update skip locked;
    if v_pkg is null then continue; end if; -- no package: that device waits
    update key_package set consumed_at = now() where id = v_pkg;
    out_device_id := r.id;
    out_account_id := r.account_id;
    select kp.data into out_key_package from key_package kp where kp.id = v_pkg;
    return next;
  end loop;
end;
$$;

revoke all on function claim_device_key_packages(uuid[]) from public;
grant execute on function claim_device_key_packages(uuid[]) to authenticated;

-- Publish a Commit made at p_epoch, with Welcomes for any added devices
-- (p_welcomes: [{"device": uuid, "welcome": hex}]). Optionally adds
-- p_add_member to the conversation in the same transaction (adding a person
-- to an encrypted group). Returns false if another commit got there first.
create or replace function publish_mls_commit(
  p_conversation uuid,
  p_device uuid,
  p_epoch bigint,
  p_commit bytea,
  p_welcomes jsonb default '[]',
  p_add_member uuid default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_epoch bigint;
  w jsonb;
begin
  if not is_conversation_member(p_conversation, v_me) then
    raise exception 'not a member of this conversation';
  end if;
  if not exists (select 1 from device where id = p_device and account_id = v_me
                 and revoked_at is null) then
    raise exception 'not one of your devices';
  end if;
  if not exists (select 1 from conversation where id = p_conversation and e2ee) then
    raise exception 'not an encrypted conversation';
  end if;
  if p_add_member is not null then
    if not exists (select 1 from conversation where id = p_conversation and is_group) then
      raise exception 'not a group';
    end if;
    if blocked_between(v_me, p_add_member) then raise exception 'not available'; end if;
  end if;

  select epoch into v_epoch from mls_group_state
   where conversation_id = p_conversation for update;
  if v_epoch is null or v_epoch <> p_epoch then
    return false;
  end if;

  insert into mls_message (conversation_id, sender_device_id, epoch, content_type, ciphertext)
  values (p_conversation, p_device, p_epoch, 'commit', p_commit);
  for w in select * from jsonb_array_elements(coalesce(p_welcomes, '[]'))
  loop
    insert into mls_message (conversation_id, sender_device_id, recipient_device_id,
                             epoch, content_type, ciphertext)
    values (p_conversation, p_device, (w->>'device')::uuid,
            p_epoch + 1, 'welcome', decode(w->>'welcome', 'hex'));
  end loop;
  update mls_group_state set epoch = p_epoch + 1, updated_at = now()
   where conversation_id = p_conversation;

  if p_add_member is not null then
    insert into conversation_member (conversation_id, member_id, state)
    values (p_conversation, p_add_member, 'active')
    on conflict do nothing;
  end if;
  return true;
end;
$$;

revoke all on function publish_mls_commit(uuid, uuid, bigint, bytea, jsonb, uuid) from public;
grant execute on function publish_mls_commit(uuid, uuid, bigint, bytea, jsonb, uuid) to authenticated;

-- Devices currently entitled to be in an encrypted conversation: every
-- non-revoked device of every member. Compared against the MLS roster.
create or replace function conversation_devices(p_conversation uuid)
returns table (device_id uuid, account_id uuid)
language sql stable security definer set search_path = public as $$
  select d.id, d.account_id
  from conversation_member cm
  join device d on d.account_id = cm.member_id and d.revoked_at is null
  where cm.conversation_id = p_conversation
    and is_conversation_member(p_conversation, auth.uid());
$$;

revoke all on function conversation_devices(uuid) from public;
grant execute on function conversation_devices(uuid) to authenticated;

-- Supabase grants anon EXECUTE on new functions directly, so revoking from
-- public alone doesn't remove it (AGENTS.md). Covers 2.5-3's functions too.
-- (All of these already refuse callers without auth.uid().)
revoke execute on function claim_device_key_packages(uuid[]) from anon;
revoke execute on function publish_mls_commit(uuid, uuid, bigint, bytea, jsonb, uuid) from anon;
revoke execute on function conversation_devices(uuid) from anon;
revoke execute on function begin_conversation_e2ee(uuid, text, bigint) from anon;
revoke execute on function enable_conversation_e2ee(uuid) from anon;
revoke execute on function messages_page(uuid, timestamptz, int) from anon;
revoke execute on function conversations_list(boolean) from anon;
revoke all on function messages_page(uuid, timestamptz, int) from public;
revoke all on function conversations_list(boolean) from public;
grant execute on function messages_page(uuid, timestamptz, int) to authenticated;
grant execute on function conversations_list(boolean) to authenticated;
