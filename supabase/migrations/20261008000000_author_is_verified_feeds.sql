-- author_is_verified on friends and local.
-- Version is 20261008000000 because 20261004000000 is already used.
-- Drop first: CREATE OR REPLACE cannot add a return column.

drop function if exists feed_friends(timestamptz, int);
drop function if exists feed_local(timestamptz, int);

-- Fix missing author_is_verified in feed_friends and feed_local.
-- This aligns them with the updated schema used in feed_latest and recommend_posts_for_user.

CREATE OR REPLACE FUNCTION feed_friends(
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, reason text,
  author_is_verified boolean
)
language sql stable as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    case when p.author_id = auth.uid() then 'Your post'
         else 'You and @' || a.handle || ' follow each other' end,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and (
      p.author_id = auth.uid()
      or (
        exists (select 1 from follow f
                where f.follower_id = auth.uid() and f.followee_id = p.author_id)
        and exists (select 1 from follow fb
                    where fb.follower_id = p.author_id and fb.followee_id = auth.uid())
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

CREATE OR REPLACE FUNCTION feed_local(
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, reason text,
  author_is_verified boolean
)
language sql stable set search_path = public as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    case when p.author_id = auth.uid() then 'Your post'
         else 'Public on Peak — from ' || coalesce(a.domain, 'peak.social') end,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and p.visibility = 'public'
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

GRANT EXECUTE ON FUNCTION feed_friends(timestamptz, int) TO authenticated;
GRANT EXECUTE ON FUNCTION feed_local(timestamptz, int) TO authenticated;
