-- Hosted already applied the broken 20261001000002_fix_feed_rpcs.sql as
-- originally written (see that file's current header comment for the full
-- story). By now hosted has THREE things on top of each other:
--   1. feed_latest(timestamptz, int)  — from 20261001000000, stripped shape
--   2. feed_latest(int)               — from 20261001000002 as first written,
--                                        broken (selected nonexistent
--                                        p.author_handle/media/etc., no
--                                        visibility filter)
--   3. feed_trending(int)             — from 20261001000002, same bug
-- This migration drops both feed_latest overloads and re-applies the
-- corrected single-signature definitions from 20261001000002 (now fixed)
-- verbatim, so hosted matches a fresh `db reset`.

DROP FUNCTION IF EXISTS feed_latest(timestamptz, int);
DROP FUNCTION IF EXISTS feed_latest(int);

CREATE OR REPLACE FUNCTION feed_trending(p_limit int DEFAULT 30)
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
    'Trending on Peak'::text,
    p.reply_to, 0
  FROM post p
  JOIN profile a ON a.id = p.author_id
  WHERE p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and p.visibility = 'public'
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  ORDER BY p.rank_score DESC, p.created_at DESC
  LIMIT least(p_limit, 100);
$$;

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
      else 'You follow @' || a.handle
    end,
    p.reply_to, 0
  FROM post p
  JOIN profile a ON a.id = p.author_id
  WHERE p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and (
      p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  ORDER BY p.created_at DESC
  LIMIT least(p_limit, 100);
$$;

revoke all on function feed_trending(int) from public;
revoke all on function feed_latest(timestamptz, int) from public;
grant execute on function feed_trending(int) to authenticated;
grant execute on function feed_latest(timestamptz, int) to authenticated;
