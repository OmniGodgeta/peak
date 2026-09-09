-- Peak — Phase 2.5-0: E2E encryption foundation (schema only).
--
-- No message content moves to these tables yet — the client still runs the
-- transport-only path until the native MLS lib is wired (see docs/ENCRYPTION.md).
-- Everything here holds ciphertext or public keys only; the server can never
-- read message content or derive group keys.

-- ── device: one app install, with a long-lived signature key ────────────────
create table device (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references profile (id) on delete cascade,
  public_sig_key bytea not null,                 -- Ed25519 public key
  label          text check (char_length(label) <= 60),
  created_at     timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  revoked_at     timestamptz
);
create index device_by_account on device (account_id) where revoked_at is null;

alter table device enable row level security;

-- Anyone can see the (non-revoked) devices of an account they could message —
-- needed to add all of someone's devices to an MLS group. Blocks still apply.
create policy device_select on device for select using (
  not blocked_between(auth.uid(), account_id)
);
create policy device_insert on device for insert with check (account_id = auth.uid());
create policy device_update on device for update
  using (account_id = auth.uid()) with check (account_id = auth.uid());
create policy device_delete on device for delete using (account_id = auth.uid());

-- ── key_package: pre-published single-use MLS KeyPackages per device ─────────
create table key_package (
  id          uuid primary key default gen_random_uuid(),
  device_id   uuid not null references device (id) on delete cascade,
  data        bytea not null,                    -- opaque MLS KeyPackage
  consumed_at timestamptz,
  created_at  timestamptz not null default now()
);
create index key_package_unclaimed
  on key_package (device_id) where consumed_at is null;

alter table key_package enable row level security;

-- A device manages its own packages; everyone else goes through claim_key_packages.
create policy key_package_owner on key_package for all
  using (exists (
    select 1 from device d where d.id = device_id and d.account_id = auth.uid()
  ))
  with check (exists (
    select 1 from device d where d.id = device_id and d.account_id = auth.uid()
  ));

-- Hand out one unconsumed key package for every non-revoked device of each
-- requested account. SECURITY DEFINER so it can mark packages consumed.
-- Returns one row per device that has at least one usable package.
create or replace function claim_key_packages(p_accounts uuid[])
returns table (out_device_id uuid, out_account_id uuid, out_key_package bytea)
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  r record;
  v_pkg_id uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;

  for r in
    select d.id as dev_id, d.account_id as acct_id
    from device d
    where d.account_id = any (p_accounts)
      and d.revoked_at is null
      and not blocked_between(v_me, d.account_id)
  loop
    -- oldest unconsumed package for this device
    select kp.id into v_pkg_id
    from key_package kp
    where kp.device_id = r.dev_id and kp.consumed_at is null
    order by kp.created_at
    limit 1;

    if v_pkg_id is not null then
      update key_package set consumed_at = now() where id = v_pkg_id;
      out_device_id := r.dev_id;
      out_account_id := r.acct_id;
      select kp.data into out_key_package from key_package kp where kp.id = v_pkg_id;
      return next;
    else
      -- pool exhausted: reuse the newest package rather than fail the whole
      -- conversation (the client replenishes aggressively; last-resort only)
      select kp.data into out_key_package
      from key_package kp
      where kp.device_id = r.dev_id
      order by kp.created_at desc
      limit 1;
      if out_key_package is not null then
        out_device_id := r.dev_id;
        out_account_id := r.acct_id;
        return next;
      end if;
    end if;
  end loop;
end;
$$;

revoke all on function claim_key_packages(uuid[]) from public;
grant execute on function claim_key_packages(uuid[]) to authenticated;

-- ── mls_group_state: public group state per conversation, per epoch ─────────
create table mls_group_state (
  conversation_id    uuid primary key references conversation (id) on delete cascade,
  epoch              bigint not null default 0,
  ciphersuite        text not null,
  public_group_state bytea,                       -- opaque, for external joiners
  updated_at         timestamptz not null default now()
);

alter table mls_group_state enable row level security;
create policy mls_group_state_select on mls_group_state for select
  using (is_conversation_member(conversation_id, auth.uid()));
create policy mls_group_state_write on mls_group_state for all
  using (is_conversation_member(conversation_id, auth.uid()))
  with check (is_conversation_member(conversation_id, auth.uid()));

-- ── mls_message: ciphertext blobs relayed between devices ──────────────────
create type mls_content_type as enum ('application', 'commit', 'proposal', 'welcome');

create table mls_message (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references conversation (id) on delete cascade,
  sender_device_id uuid references device (id) on delete set null,
  epoch            bigint not null,
  content_type     mls_content_type not null,
  ciphertext       bytea not null,
  -- for a 'welcome', the specific device it's addressed to
  recipient_device_id uuid references device (id) on delete cascade,
  created_at       timestamptz not null default now()
);
create index mls_message_conv_time on mls_message (conversation_id, created_at);
create index mls_message_welcome_for
  on mls_message (recipient_device_id) where content_type = 'welcome';

alter table mls_message enable row level security;

create policy mls_message_select on mls_message for select using (
  is_conversation_member(conversation_id, auth.uid())
  and (
    recipient_device_id is null
    or exists (select 1 from device d
               where d.id = recipient_device_id and d.account_id = auth.uid())
  )
);
create policy mls_message_insert on mls_message for insert with check (
  is_conversation_member(conversation_id, auth.uid())
  and (
    sender_device_id is null
    or exists (select 1 from device d
               where d.id = sender_device_id and d.account_id = auth.uid())
  )
);

-- ── history_blob: encrypted message-history archive for new-device restore ──
create table history_blob (
  account_id uuid not null references profile (id) on delete cascade,
  seq        bigint not null,
  ciphertext bytea not null,                      -- encrypted under a user-held key
  created_at timestamptz not null default now(),
  primary key (account_id, seq)
);

alter table history_blob enable row level security;
create policy history_blob_own on history_blob for all
  using (account_id = auth.uid()) with check (account_id = auth.uid());

-- ── conversation gets an encryption mode flag ─────────────────────────────
alter table conversation
  add column e2ee boolean not null default false;

comment on column conversation.e2ee is
  'When true, content lives in mls_message (ciphertext); message.body is empty. '
  'Existing conversations stay false until the Phase 2.5 cutover.';

-- Relay MLS blobs + group-state changes in realtime.
alter publication supabase_realtime add table mls_message;
alter publication supabase_realtime add table mls_group_state;
