-- Peak — Phase 2 messaging: 1:1 and group conversations over Realtime.
--
-- Transport security only in this migration. The MLS end-to-end layer is
-- Phase 2.5 (docs/ROADMAP.md): `message.body` becomes ciphertext and the
-- server stores key material it can't read. The schema is shaped so that
-- swap is additive (a `ciphertext` column + a per-conversation key epoch).

create type conversation_member_state as enum ('active', 'request');

-- ── conversation ────────────────────────────────────────────────────────────
create table conversation (
  id               uuid primary key default gen_random_uuid(),
  is_group         boolean not null default false,
  title            text check (char_length(title) <= 80),   -- group only
  created_by       uuid references profile (id) on delete set null,
  created_at       timestamptz not null default now(),
  last_message_at  timestamptz not null default now()
);

create index conversation_recent_idx on conversation (last_message_at desc);

-- ── conversation_member ─────────────────────────────────────────────────────
create table conversation_member (
  conversation_id      uuid not null references conversation (id) on delete cascade,
  member_id            uuid not null references profile (id) on delete cascade,
  state                conversation_member_state not null default 'active',
  joined_at            timestamptz not null default now(),
  last_read_at         timestamptz not null default now(),
  notifications_muted  boolean not null default false,
  primary key (conversation_id, member_id)
);

create index conversation_member_by_member on conversation_member (member_id);

-- ── message ─────────────────────────────────────────────────────────────────
create table message (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references conversation (id) on delete cascade,
  sender_id        uuid references profile (id) on delete set null,
  body             text not null default '' check (char_length(body) <= 8000),
  reply_to         uuid references message (id) on delete set null,
  edited_at        timestamptz,
  deleted_at       timestamptz,          -- delete-for-everyone tombstone
  created_at       timestamptz not null default now()
);

create index message_conversation_time on message (conversation_id, created_at desc);

-- keep conversation.last_message_at in step
create or replace function bump_conversation_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update conversation set last_message_at = new.created_at
   where id = new.conversation_id;
  return new;
end;
$$;

create trigger message_bumps_conversation
  after insert on message
  for each row execute function bump_conversation_activity();

-- ── membership helper (SECURITY DEFINER — used inside message RLS) ───────────
create or replace function is_conversation_member(p_conversation uuid, p_user uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from conversation_member
    where conversation_id = p_conversation and member_id = p_user
  );
$$;

-- ── start_dm: find-or-create a 1:1 conversation with another account ─────────
create or replace function start_dm(p_other uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_conv uuid;
  v_other_follows_me boolean;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  if p_other = v_me then raise exception 'cannot DM yourself'; end if;
  if not exists (select 1 from profile where id = p_other) then
    raise exception 'no such account';
  end if;
  if blocked_between(v_me, p_other) then
    raise exception 'not available';
  end if;

  -- existing 1:1?
  select c.id into v_conv
  from conversation c
  where c.is_group = false
    and (select count(*) from conversation_member m where m.conversation_id = c.id) = 2
    and exists (select 1 from conversation_member m where m.conversation_id = c.id and m.member_id = v_me)
    and exists (select 1 from conversation_member m where m.conversation_id = c.id and m.member_id = p_other)
  limit 1;

  if v_conv is not null then
    return v_conv;
  end if;

  insert into conversation (is_group, created_by) values (false, v_me)
  returning id into v_conv;

  -- if the recipient doesn't follow me, their side starts as a request
  select exists (
    select 1 from follow where follower_id = p_other and followee_id = v_me
  ) into v_other_follows_me;

  insert into conversation_member (conversation_id, member_id, state) values
    (v_conv, v_me, 'active'::conversation_member_state),
    (v_conv, p_other,
      case when v_other_follows_me then 'active'::conversation_member_state
           else 'request'::conversation_member_state end);

  return v_conv;
end;
$$;

revoke all on function start_dm(uuid) from public;
grant execute on function start_dm(uuid) to authenticated;

-- ── conversations_list: the Messages tab ───────────────────────────────────
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
  -- for a 1:1, the other person
  other_id uuid,
  other_handle citext,
  other_domain text,
  other_display_name text,
  other_avatar_path text
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
    o.member_id, op.handle, op.domain, op.display_name, op.avatar_path
  from conversation c
  join conversation_member me
    on me.conversation_id = c.id and me.member_id = auth.uid()
  left join conversation_member o
    on o.conversation_id = c.id and c.is_group = false and o.member_id <> auth.uid()
  left join profile op on op.id = o.member_id
  where (p_include_requests or me.state = 'active')
  order by c.last_message_at desc;
$$;

-- ── messages_page: history for a conversation, newest first ─────────────────
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
  created_at timestamptz
)
language sql stable as $$
  select
    m.id, m.body, m.reply_to, m.sender_id,
    s.handle, s.display_name,
    m.edited_at, m.deleted_at, m.created_at
  from message m
  left join profile s on s.id = m.sender_id
  where m.conversation_id = p_conversation
    and is_conversation_member(p_conversation, auth.uid())
    and m.created_at < p_before
  order by m.created_at desc
  limit least(p_limit, 100);
$$;

-- ── mark_read + accept_request ─────────────────────────────────────────────
create or replace function mark_conversation_read(p_conversation uuid)
returns void
language sql as $$
  update conversation_member
     set last_read_at = now()
   where conversation_id = p_conversation and member_id = auth.uid();
$$;

create or replace function accept_message_request(p_conversation uuid)
returns void
language sql as $$
  update conversation_member
     set state = 'active'
   where conversation_id = p_conversation and member_id = auth.uid();
$$;

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table conversation        enable row level security;
alter table conversation_member enable row level security;
alter table message             enable row level security;

-- conversation: visible to its members
create policy conversation_select on conversation for select
  using (is_conversation_member(id, auth.uid()));

-- conversation_member: a member can see the roster of their conversations;
-- can update only their own row (last_read_at, mute, accept request)
create policy conversation_member_select on conversation_member for select
  using (is_conversation_member(conversation_id, auth.uid()));
create policy conversation_member_update on conversation_member for update
  using (member_id = auth.uid()) with check (member_id = auth.uid());

-- message: read if you're a member; send as yourself into a conversation you're
-- an active member of, and (for 1:1) only if not blocked.
create policy message_select on message for select
  using (is_conversation_member(conversation_id, auth.uid()));

create policy message_insert on message for insert with check (
  sender_id = auth.uid()
  and exists (
    select 1 from conversation_member m
    where m.conversation_id = message.conversation_id
      and m.member_id = auth.uid()
      and m.state = 'active'
  )
  and not exists (
    -- no sending into a 1:1 with someone who blocked you (or vice versa)
    select 1
    from conversation c
    join conversation_member other
      on other.conversation_id = c.id and other.member_id <> auth.uid()
    where c.id = message.conversation_id
      and c.is_group = false
      and blocked_between(auth.uid(), other.member_id)
  )
);

create policy message_update on message for update
  using (sender_id = auth.uid()) with check (sender_id = auth.uid());

-- ── Realtime: stream new messages + membership changes to clients ──────────
alter publication supabase_realtime add table message;
alter publication supabase_realtime add table conversation_member;
