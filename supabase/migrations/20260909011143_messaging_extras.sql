-- Peak — Phase 2 continued: media in DMs, edit/delete, group chats, read receipts.

-- ── Media in messages ──────────────────────────────────────────────────────
create table message_media (
  id           uuid primary key default gen_random_uuid(),
  message_id   uuid not null references message (id) on delete cascade,
  kind         media_kind not null,
  storage_path text not null,
  alt_text     text check (char_length(alt_text) <= 1000),
  width        int,
  height       int,
  duration_ms  int,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);
create index message_media_by_message on message_media (message_id);

alter table message_media enable row level security;

create policy message_media_select on message_media for select
  using (exists (
    select 1 from message m
    where m.id = message_id
      and is_conversation_member(m.conversation_id, auth.uid())
  ));
create policy message_media_write on message_media for all
  using (exists (
    select 1 from message m
    where m.id = message_id and m.sender_id = auth.uid()
  ))
  with check (exists (
    select 1 from message m
    where m.id = message_id and m.sender_id = auth.uid()
  ));

-- Private bucket — DM media is gated to conversation members via signed URLs.
-- Object path is `<conversation_id>/<uuid>.<ext>`.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'message-media', 'message-media', false,
  26214400,
  array['image/jpeg','image/png','image/webp','image/gif','image/avif']
)
on conflict (id) do nothing;

create policy "message-media: member read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'message-media'
    and is_conversation_member((storage.foldername(name))[1]::uuid, auth.uid())
  );

create policy "message-media: member write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'message-media'
    and is_conversation_member((storage.foldername(name))[1]::uuid, auth.uid())
  );

create policy "message-media: own delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'message-media' and owner = auth.uid());

-- ── Edit / delete a message ────────────────────────────────────────────────
create or replace function edit_message(p_id uuid, p_body text)
returns void language sql as $$
  update message
     set body = p_body, edited_at = now()
   where id = p_id and sender_id = auth.uid() and deleted_at is null;
$$;

create or replace function delete_message(p_id uuid)
returns void language sql as $$
  update message
     set deleted_at = now(), body = ''
   where id = p_id and sender_id = auth.uid();
$$;

-- ── Group conversations ────────────────────────────────────────────────────
create or replace function create_group(p_title text, p_members uuid[])
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_conv uuid;
  v_member uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  if coalesce(array_length(p_members, 1), 0) = 0 then
    raise exception 'a group needs at least one other member';
  end if;

  insert into conversation (is_group, title, created_by)
  values (true, nullif(trim(p_title), ''), v_me)
  returning id into v_conv;

  insert into conversation_member (conversation_id, member_id, state)
  values (v_conv, v_me, 'active');

  foreach v_member in array p_members
  loop
    if v_member <> v_me
       and exists (select 1 from profile where id = v_member)
       and not blocked_between(v_me, v_member) then
      insert into conversation_member (conversation_id, member_id, state)
      values (v_conv, v_member, 'active')
      on conflict do nothing;  -- also dedupes repeats in p_members
    end if;
  end loop;

  return v_conv;
end;
$$;

revoke all on function create_group(text, uuid[]) from public;
grant execute on function create_group(text, uuid[]) to authenticated;

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
  if blocked_between(auth.uid(), p_user) then
    raise exception 'not available';
  end if;
  insert into conversation_member (conversation_id, member_id, state)
  values (p_conversation, p_user, 'active')
  on conflict do nothing;
end;
$$;

grant execute on function add_group_member(uuid, uuid) to authenticated;

create or replace function leave_conversation(p_conversation uuid)
returns void language sql as $$
  delete from conversation_member
   where conversation_id = p_conversation and member_id = auth.uid();
$$;

-- a member may remove their own membership (leave)
create policy conversation_member_delete on conversation_member for delete
  using (member_id = auth.uid());

-- Roster for a group's settings screen.
create or replace function conversation_members(p_conversation uuid)
returns table (
  member_id uuid, handle citext, domain text,
  display_name text, avatar_path text, is_teen boolean,
  state conversation_member_state, joined_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select cm.member_id, p.handle, p.domain, p.display_name, p.avatar_path,
         (p.account_kind = 'teen'), cm.state, cm.joined_at
  from conversation_member cm
  join profile p on p.id = cm.member_id
  where cm.conversation_id = p_conversation
    and is_conversation_member(p_conversation, auth.uid())
  order by cm.joined_at;
$$;

-- ── Read receipts (mutual opt-in, off by default) ──────────────────────────
alter table conversation_member
  add column share_read_receipts boolean not null default false;

-- Other members' read positions, but only when both sides share receipts.
create or replace function conversation_read_state(p_conversation uuid)
returns table (member_id uuid, last_read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select o.member_id, o.last_read_at
  from conversation_member me
  join conversation_member o
    on o.conversation_id = me.conversation_id and o.member_id <> me.member_id
  where me.conversation_id = p_conversation
    and me.member_id = auth.uid()
    and me.share_read_receipts
    and o.share_read_receipts;
$$;

-- ── messages_page now carries media + a reply preview ──────────────────────
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
  media jsonb
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
    ), '[]'::jsonb)
  from message m
  left join profile s on s.id = m.sender_id
  where m.conversation_id = p_conversation
    and is_conversation_member(p_conversation, auth.uid())
    and m.created_at < p_before
  order by m.created_at desc
  limit least(p_limit, 100);
$$;

alter publication supabase_realtime add table message_media;
