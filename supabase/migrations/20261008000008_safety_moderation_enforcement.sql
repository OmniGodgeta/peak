-- Peak — Phase 5 Supplement: Safety & Moderation Features (v5 - Complete Enforcement)
-- This migration implements the final enforcement of safety features in RLS.
-- It adds harassment shield enforcement to can_view_post and completes the grace period logic.

-- 1. Enforce Harassment Shield in can_view_post.
-- If a user has an active harassment shield (harassment_shield_expires_at > now()), 
-- their posts should be hidden from everyone except themselves.

create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    -- Requirement: Hide posts from authors in their 30-day deletion grace period OR under active harassment shield.
    and (
      p_post.author_id = viewer
      or not exists (
        select 1 from profile p 
        where p.id = p_post.author_id 
          and (
            -- Deletion Grace Period Check
            (p.deletion_requested_at is not null and p.deletion_requested_at > now() - interval '30 days')
            or
            -- Harassment Shield Enforcement
            (p.harassment_shield_expires_at is not null and p.harassment_shield_expires_at > now())
          )
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

-- Note: Timed mute is handled via existing 'mute' table with 'expires_at'.
-- The app (frontend) will create entries in the 'mute' table to enforce this.
