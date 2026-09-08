-- Peak — people discovery and profile views for the follow graph.
--
-- Following/unfollowing itself is plain inserts/deletes on `follow`, already
-- gated by RLS. These RPCs give the client the read side: search, and a
-- profile view that bundles the follow relationship + counts.

-- ── search_people: by handle or display name ────────────────────────────────
-- Excludes: yourself, anyone blocked in either direction, and non-discoverable
-- accounts (teens, and adults who opted out) unless you already follow them.
create or replace function search_people(q text, p_limit int default 20)
returns table (
  id uuid,
  handle citext,
  domain text,
  display_name text,
  bio text,
  avatar_path text,
  is_teen boolean,
  is_following boolean
)
language sql stable as $$
  select
    p.id, p.handle, p.domain, p.display_name, p.bio, p.avatar_path,
    (p.account_kind = 'teen'),
    exists (select 1 from follow f
            where f.follower_id = auth.uid() and f.followee_id = p.id)
  from profile p
  where p.id <> auth.uid()
    and not blocked_between(auth.uid(), p.id)
    and (
      p.is_discoverable
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.id)
    )
    and (
      length(trim(q)) >= 2
      and (
        p.handle ilike trim(q) || '%'
        or p.display_name ilike '%' || trim(q) || '%'
      )
    )
  order by
    (p.handle ilike trim(q) || '%') desc,   -- handle-prefix hits first
    p.handle
  limit least(p_limit, 50);
$$;

-- ── profile_view: a public profile plus the viewer's relationship to it ──────
create or replace function profile_view(p_handle citext, p_domain text default 'peak.social')
returns table (
  id uuid,
  handle citext,
  domain text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  pronouns text,
  location_coarse text,
  links jsonb,
  is_teen boolean,
  created_at timestamptz,
  is_self boolean,
  is_following boolean,
  follows_you boolean,
  show_follow_counts boolean,
  follower_count bigint,
  following_count bigint,
  post_count bigint
)
language sql stable as $$
  select
    p.id, p.handle, p.domain, p.display_name, p.bio, p.avatar_path,
    p.banner_path, p.pronouns, p.location_coarse, p.links,
    (p.account_kind = 'teen'),
    p.created_at,
    (p.id = auth.uid()),
    exists (select 1 from follow f where f.follower_id = auth.uid() and f.followee_id = p.id),
    exists (select 1 from follow f where f.follower_id = p.id and f.followee_id = auth.uid()),
    p.show_follow_counts,
    (select count(*) from follow f where f.followee_id = p.id),
    (select count(*) from follow f where f.follower_id = p.id),
    (select count(*) from post po where po.author_id = p.id and po.deleted_at is null and po.reply_to is null)
  from profile p
  where p.handle = p_handle and p.domain = p_domain
    and not blocked_between(auth.uid(), p.id);
$$;

-- ── posts_by: a user's own timeline (visibility-filtered for the viewer) ─────
create or replace function posts_by(
  p_author uuid,
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
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
  author_avatar_path text,
  author_is_teen boolean,
  reaction_count bigint,
  reply_count bigint,
  repost_count bigint,
  viewer_reacted boolean,
  viewer_reposted boolean
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
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid())
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_author
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
  order by p.created_at desc
  limit least(p_limit, 100);
$$;
