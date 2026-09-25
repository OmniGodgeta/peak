-- Peak — Phase 7: Voice notes and disappearing messages.

-- Add disappearing settings to conversation.
alter table conversation add column disappearing_enabled boolean not null default false;

-- Add expiration to message for ephemeral content.
alter table message add column expires_at timestamptz;

-- Update RLS to hide expired messages from all members.
drop policy if exists message_select on message;
create policy message_select on message for select
  using (
    is_conversation_member(conversation_id, auth.uid())
    and (expires_at is null or expires_at > now())
  );

-- Create index for efficient expiry filtering/purging.
create index message_expiry_idx on message (expires_at) where expires_at is not null;
