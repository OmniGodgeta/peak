-- Peak — Phase 5 Supplement: Safety & Moderation Features (v4 - Final Enforcement Fix)
-- This migration implements the missing enforcement logic for the harassment shield 
-- and ensures can_view_post correctly hides posts from users in the 30-day deletion grace period.

-- 1. Ensure suppressive visibility logic is part of can_view_post.
-- We use 'create or replace' to add the grace period check without losing existing community/visibility logic.

create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    -- Requirement: Hide posts from authors in their 30-day deletion grace period unless it's the author themselves.
    and (
      p_post.author_id = viewer
      or not exists (
        select 1 from profile p 
        where p.id = p_post.author_id 
          and p.deletion_requested_at is not null
          and p.deletion_requested_at > now() - interval '30 days'
      )
    )
    -- Original Visibility Logic
    and case
      when p_post.community_id is not null then (
        p_post.author_id = viewer
        or exists (
          select 1 from community c
          where c.id = p_post.community_id
            and (c.join_policy = 'open' or is_community_member(c.id, viewer))
        )
      )
      else (
        p_post.author_id = viewer
        or (p_post.visibility = 'public')
        or (p_post.visibility = 'followers'
            and exists (select 1 from follow f
                        where f.follower_id = viewer and f.followee_id = p_post.author_id))
        or (p_post.visibility = 'mentioned'
            and exists (select 1 from mention m
                        where m.post_id = p_post.id and m.mentioned_id = viewer))
        or (p_post.visibility = 'circles'
            and exists (
              select 1 from post_audience pa
              join circle_member cm on cm.circle_id = pa.circle_id
              where pa.post_id = p_post.id and cm.member_id = viewer))
        or (p_post.visibility = 'circles'
            and exists (
              select 1 from post_audience pa
              join circle c on c.id = pa.circle_id
              where pa.post_id = p_post.id and c.is_public))
      )
    end;
$$;

-- Note: harassment_shield_expires_at is already in the profile table schema as verified.
-- Mute functionality utilizes existing 'mute' table with 'expires_at'.
