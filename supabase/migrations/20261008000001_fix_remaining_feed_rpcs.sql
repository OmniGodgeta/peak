-- author_is_verified on remaining feeds.
-- This migration adds author_is_verified to feed_custom, community_feed, posts_by, and post_thread.

drop function if exists feed_custom(uuid, timestamptz, int);
drop function if exists community_feed(uuid, timestamptz, int);
drop function if exists posts_by(uuid, timestamptz, int);
drop function if exists post_thread(uuid);

-- 1. feed_custom
CREATE OR REPLACE FUNCTION feed_custom(
  p_feed_id uuid,
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
language plpgsql stable security definer set search_path = public as $$
declare
  r jsonb;
  has_positive boolean;
begin
  select cf.rules into r from custom_feed cf
  where cf.id = p_feed_id and (cf.owner_id = auth.uid() or cf.is_public);
  if r is null then raise exception 'feed not found'; end if;

  has_positive :=
    (jsonb_array_length(coalesce(r->'communities', '[]')) > 0) or
    (jsonb_array_length(coalesce(r->'from', '[]')) > 0) or
    (jsonb_array_length(coalesce(r->'any_words', '[]')) > 0);

  return query
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction rc where rc.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction rc where rc.post_id = p.id and rc.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    'From a custom feed'::text,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
    and (
      has_positive
      or p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    and (
      jsonb_array_length(coalesce(r->'communities', '[]')) = 0
      or p.community_id in (select (jsonb_array_elements_text(r->'communities'))::uuid)
    )
    and (
      jsonb_array_length(coalesce(r->'from', '[]')) = 0
      or p.author_id in (select (jsonb_array_elements_text(r->'from'))::uuid)
    )
    and (
      jsonb_array_length(coalesce(r->'any_words', '[]')) = 0
      or exists (
        select 1 from jsonb_array_elements_text(r->'any_words') w
        where p.body ilike '%' || w || '%'
           or coalesce(p.title, '') ilike '%' || w || '%')
    )
    and not exists (
      select 1 from jsonb_array_elements_text(coalesce(r->'not_words', '[]')) w
      where p.body ilike '%' || w || '%'
    )
    and (
      coalesce((r->>'only_media')::boolean, false) = false
      or exists (select 1 from post_media pm where pm.post_id = p.id)
    )
  order by p.created_at desc
  limit least(p_limit, 100);
end;
$$;

-- 2. community_feed
CREATE OR REPLACE FUNCTION community_feed(
  p_community_id uuid,
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
  title text, long_form boolean, is_pinned boolean,
  label text, label_note text, author_flair text,
  channel_id uuid, channel_name text,
  author_is_verified boolean
)
language sql stable security definer set search_path = public as $$
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
    p.title, p.long_form, false,
    pl.label, pl.note,
    (select cm.flair from community_member cm
     where cm.community_id = p_community_id and cm.member_id = p.author_id),
    p.channel_id, ch.name,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  left join post_label pl on pl.post_id = p.id
  left join community_channel ch on ch.id = p.channel_id
  where p.community_id = p_community_id
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

-- 3. posts_by
CREATE OR REPLACE FUNCTION posts_by(
  p_profile_id uuid,
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
  title text, long_form boolean, is_pinned boolean,
  author_is_verified boolean
)
language sql stable security definer set search_path = public as $$
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
    p.title, p.long_form, false,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_profile_id
    and p.deleted_at is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

-- 4. post_thread
CREATE OR REPLACE FUNCTION post_thread(p_root uuid)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, depth int,
  author_is_verified boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  with RECURSIVE thread AS (
    select p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
           p.created_at, p.edited_at, p.author_id, p.title, p.long_form, 
           p.channel_id, p.community_id, 0 as depth from post p where p.id = p_root
    union all
    select p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
           p.created_at, p.edited_at, p.author_id, p.title, p.long_form, 
           p.channel_id, p.community_id, t.depth + 1 from post p join thread t on p.reply_to = t.id
    where p.deleted_at is null
  )
  select
    t.id, t.body, t.content_warning, t.is_sensitive, t.visibility,
    t.created_at, t.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = t.id),
    (select count(*) from post pr where pr.reply_to = t.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = t.id),
    exists (select 1 from reaction r where r.post_id = t.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = t.id and rp.actor_id = auth.uid()),
    post_media_json(t.id),
    t.title, t.long_form, t.depth,
    is_verified_person(a.id)
  from thread t
  join profile a on a.id = t.author_id
  where can_view_post((select p.* from post p where p.id = t.id), auth.uid())
  order by t.depth, t.created_at;
end;
$$;

GRANT EXECUTE ON FUNCTION feed_custom(uuid, timestamptz, int) TO authenticated;
GRANT EXECUTE ON FUNCTION community_feed(uuid, timestamptz, int) TO authenticated;
GRANT EXECUTE ON FUNCTION posts_by(uuid, timestamptz, int) TO authenticated;
GRANT EXECUTE ON FUNCTION post_thread(uuid) TO authenticated;
