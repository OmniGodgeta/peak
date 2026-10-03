-- E2EE stage 2.5-3: end-to-end encrypted conversations (docs/ENCRYPTION.md).
--
-- An encrypted conversation is one MLS group. Its messages keep their normal
-- `message` row (ordering, replies, reactions, read state and the delete
-- tombstone all work unchanged), but the content is MLS ciphertext in
-- `message.ciphertext` and `body` stays empty. Commits and Welcomes travel in
-- `mls_message`, as designed in 2.5-0.
--
-- Not yet (later stages): adding members or devices to an encrypted
-- conversation (2.5-4), editing an encrypted message, encrypted attachments.
-- Those are refused here so nothing can quietly fall back to plaintext.

alter table message
  add column ciphertext bytea,
  add column mls_epoch bigint,
  add constraint message_e2ee_body_empty check (ciphertext is null or body = '');

comment on column message.ciphertext is
  'MLS PrivateMessage for conversations with e2ee = true; body is then empty.';

alter table mls_group_state
  add column created_by uuid references profile (id) on delete set null default auth.uid();

-- Plaintext can't land in an encrypted conversation, and ciphertext can't
-- land in a plaintext one (the client would have nothing to decrypt it with).
create or replace function message_e2ee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_e2ee boolean;
begin
  select e2ee into v_e2ee from conversation where id = new.conversation_id;
  if coalesce(v_e2ee, false) and new.ciphertext is null and new.deleted_at is null then
    raise exception 'this conversation is end-to-end encrypted';
  end if;
  if not coalesce(v_e2ee, false) and new.ciphertext is not null then
    raise exception 'this conversation is not end-to-end encrypted';
  end if;
  return new;
end;
$$;

create trigger message_e2ee_guard
  before insert on message
  for each row execute function message_e2ee_guard();

create or replace function message_media_e2ee_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from message m join conversation c on c.id = m.conversation_id
             where m.id = new.message_id and c.e2ee) then
    raise exception 'attachments are not supported in encrypted conversations yet';
  end if;
  return new;
end;
$$;

create trigger message_media_e2ee_guard
  before insert on message_media
  for each row execute function message_media_e2ee_guard();

-- Step 1 of setting up encryption: claim the conversation's MLS group.
-- Returns false if another member's device got there first (it then sends us
-- a Welcome) or if plaintext messages already exist (the conversation stays
-- plaintext; 2.5-7 handles migrating those).
create or replace function begin_conversation_e2ee(
  p_conversation uuid,
  p_ciphersuite text,
  p_epoch bigint
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not is_conversation_member(p_conversation, auth.uid()) then
    raise exception 'not a member of this conversation';
  end if;
  if exists (select 1 from message where conversation_id = p_conversation) then
    return false;
  end if;
  insert into mls_group_state (conversation_id, epoch, ciphersuite, created_by)
  values (p_conversation, p_epoch, p_ciphersuite, auth.uid())
  on conflict (conversation_id) do nothing;
  return found;
end;
$$;

-- Step 2, after the Welcomes are stored: switch the conversation over.
create or replace function enable_conversation_e2ee(p_conversation uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from mls_group_state
                 where conversation_id = p_conversation and created_by = auth.uid()) then
    raise exception 'no MLS group claimed by you for this conversation';
  end if;
  if exists (select 1 from message
             where conversation_id = p_conversation and ciphertext is null) then
    return false; -- someone already sent plaintext; it stays a plaintext conversation
  end if;
  update conversation set e2ee = true where id = p_conversation;
  return true;
end;
$$;

revoke all on function begin_conversation_e2ee(uuid, text, bigint) from public;
revoke all on function enable_conversation_e2ee(uuid) from public;
grant execute on function begin_conversation_e2ee(uuid, text, bigint) to authenticated;
grant execute on function enable_conversation_e2ee(uuid) to authenticated;

-- Members/devices can't be added to an encrypted group until 2.5-4.
create or replace function add_group_member(p_conversation uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_conversation_member(p_conversation, auth.uid()) then
    raise exception 'not a member of this conversation';
  end if;
  if not exists (select 1 from conversation where id = p_conversation and is_group) then
    raise exception 'not a group';
  end if;
  if exists (select 1 from conversation where id = p_conversation and e2ee) then
    raise exception 'members cannot be added to an encrypted group yet';
  end if;
  if blocked_between(auth.uid(), p_user) then
    raise exception 'not available';
  end if;
  insert into conversation_member (conversation_id, member_id, state)
  values (p_conversation, p_user, 'active')
  on conflict do nothing;
end;
$$;

create or replace function edit_message(p_id uuid, p_body text)
returns void language sql as $$
  update message
     set body = p_body, edited_at = now()
   where id = p_id and sender_id = auth.uid() and deleted_at is null
     and ciphertext is null;
$$;

create or replace function delete_message(p_id uuid)
returns void language sql as $$
  update message
     set deleted_at = now(), body = '', ciphertext = null
   where id = p_id and sender_id = auth.uid();
$$;

-- messages_page / conversations_list carry the encryption fields.
drop function if exists messages_page(uuid, timestamptz, int);
create or replace function messages_page(
  p_conversation uuid,
  p_before timestamptz default now(),
  p_limit int default 40
)
returns table (
  id uuid,
  body text,
  reply_to uuid,
  sender_id uuid,
  sender_handle citext,
  sender_display_name text,
  edited_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz,
  media jsonb,
  ciphertext bytea,
  mls_epoch bigint
)
language sql stable as $$
  select
    m.id, m.body, m.reply_to, m.sender_id,
    s.handle, s.display_name,
    m.edited_at, m.deleted_at, m.created_at,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'kind', mm.kind, 'storage_path', mm.storage_path,
        'alt_text', mm.alt_text, 'width', mm.width, 'height', mm.height
      ) order by mm.sort_order)
      from message_media mm where mm.message_id = m.id
    ), '[]'::jsonb),
    m.ciphertext, m.mls_epoch
  from message m
  left join profile s on s.id = m.sender_id
  where m.conversation_id = p_conversation
    and is_conversation_member(p_conversation, auth.uid())
    and m.created_at < p_before
  order by m.created_at desc
  limit least(p_limit, 100);
$$;

drop function if exists conversations_list(boolean);
create or replace function conversations_list(p_include_requests boolean default false)
returns table (
  id uuid,
  is_group boolean,
  title text,
  last_message_at timestamptz,
  my_state conversation_member_state,
  unread_count bigint,
  last_message_body text,
  last_message_sender uuid,
  other_id uuid,
  other_handle citext,
  other_domain text,
  other_display_name text,
  other_avatar_path text,
  e2ee boolean
)
language sql stable security definer set search_path = public as $$
  select
    c.id, c.is_group, c.title, c.last_message_at, me.state,
    (select count(*) from message m
     where m.conversation_id = c.id and m.created_at > me.last_read_at
       and m.sender_id is distinct from auth.uid() and m.deleted_at is null),
    (select m.body from message m
     where m.conversation_id = c.id and m.deleted_at is null
     order by m.created_at desc limit 1),
    (select m.sender_id from message m
     where m.conversation_id = c.id and m.deleted_at is null
     order by m.created_at desc limit 1),
    o.member_id, op.handle, op.domain, op.display_name, op.avatar_path,
    c.e2ee
  from conversation c
  join conversation_member me
    on me.conversation_id = c.id and me.member_id = auth.uid()
  left join conversation_member o
    on o.conversation_id = c.id and c.is_group = false and o.member_id <> auth.uid()
  left join profile op on op.id = o.member_id
  where (p_include_requests or me.state = 'active')
  order by c.last_message_at desc;
$$;

grant execute on function messages_page(uuid, timestamptz, int) to authenticated;
grant execute on function conversations_list(boolean) to authenticated;
