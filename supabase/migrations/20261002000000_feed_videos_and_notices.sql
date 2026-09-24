-- Public videos show up in Latest even when you do not follow the author,
-- and in-app notices fire for likes, replies, and follows. Push is later.

CREATE OR REPLACE FUNCTION feed_latest(
  p_before timestamptz DEFAULT now(),
  p_limit int DEFAULT 30
)
RETURNS TABLE (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility post_visibility,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle citext,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to uuid,
    depth int
)
LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, a.handle, a.domain,
    a.display_name, (a.account_kind = 'teen'), a.avatar_path,
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    false,
    null::text, null::text, null::text, p.channel_id, null::text,
    case
      when p.author_id = auth.uid() then 'Your post'
      when exists (select 1 from follow fb
                   where fb.follower_id = a.id and fb.followee_id = auth.uid())
        then 'You and @' || a.handle || ' follow each other'
      when exists (select 1 from follow f
                   where f.follower_id = auth.uid() and f.followee_id = p.author_id)
        then 'You follow @' || a.handle
      when exists (select 1 from post_media pm
                   where pm.post_id = p.id and pm.kind = 'video')
        then 'Video on Peak'
      else 'On Peak'
    end,
    p.reply_to, 0
  FROM post p
  JOIN profile a ON a.id = p.author_id
  WHERE p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and (
      (
        p.community_id is null
        and (
          p.author_id = auth.uid()
          or exists (select 1 from follow f
                     where f.follower_id = auth.uid() and f.followee_id = p.author_id)
        )
      )
      or (
        p.visibility = 'public'
        and exists (select 1 from post_media pm
                    where pm.post_id = p.id and pm.kind = 'video')
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  ORDER BY p.created_at DESC
  LIMIT least(p_limit, 100);
$$;

-- Notices. In-app only; no push provider.
create table if not exists user_notification (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references profile (id) on delete cascade,
  actor_id     uuid references profile (id) on delete set null,
  kind         text not null check (kind in ('like', 'reply', 'follow')),
  post_id      uuid references post (id) on delete cascade,
  created_at   timestamptz not null default now(),
  read_at      timestamptz
);

create index if not exists user_notification_recipient_idx
  on user_notification (recipient_id, created_at desc);

alter table user_notification enable row level security;

drop policy if exists user_notification_select on user_notification;
create policy user_notification_select on user_notification
  for select using (recipient_id = auth.uid());

drop policy if exists user_notification_update on user_notification;
create policy user_notification_update on user_notification
  for update using (recipient_id = auth.uid())
  with check (recipient_id = auth.uid());

create or replace function notify_on_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
begin
  select author_id into v_author from post where id = new.post_id;
  if v_author is not null and v_author <> new.actor_id then
    insert into user_notification (recipient_id, actor_id, kind, post_id)
    values (v_author, new.actor_id, 'like', new.post_id);
  end if;
  return new;
end;
$$;

drop trigger if exists user_notification_reaction on reaction;
create trigger user_notification_reaction
  after insert on reaction
  for each row execute function notify_on_reaction();

create or replace function notify_on_reply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
begin
  if new.reply_to is null or new.author_id is null then
    return new;
  end if;
  select author_id into v_author from post where id = new.reply_to;
  if v_author is not null and v_author <> new.author_id then
    insert into user_notification (recipient_id, actor_id, kind, post_id)
    values (v_author, new.author_id, 'reply', new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists user_notification_reply on post;
create trigger user_notification_reply
  after insert on post
  for each row execute function notify_on_reply();

create or replace function notify_on_follow()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.follower_id <> new.followee_id then
    insert into user_notification (recipient_id, actor_id, kind)
    values (new.followee_id, new.follower_id, 'follow');
  end if;
  return new;
end;
$$;

drop trigger if exists user_notification_follow on follow;
create trigger user_notification_follow
  after insert on follow
  for each row execute function notify_on_follow();

revoke all on function notify_on_reaction() from public, anon, authenticated;
revoke all on function notify_on_reply() from public, anon, authenticated;
revoke all on function notify_on_follow() from public, anon, authenticated;
