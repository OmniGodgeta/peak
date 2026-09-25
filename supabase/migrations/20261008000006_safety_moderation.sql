-- Peak — Phase 5 Supplement: Safety & Moderation Features

-- 1. Harassment Shield (Profile level)
-- Allows users to enable a period of protection where they are less discoverable/reachable.
-- Requirement: Add harassment_shield_expires_at to profile.

alter table profile
  add column harassment_shield_expires_at timestamptz;

comment on column profile.harassment_shield_expires_at is
  'Timestamp until which the user is in harassment shield mode. ';

-- 2. Refine can_view_post for Account Deletion Grace Period
-- Goal: Hide posts from accounts currently in their 30-day deletion grace period.
-- Accounts in grace period have `deletion_requested_at` set.
-- We modify `can_view_post` to handle this.

create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    -- New logic: If author is in their 30rd day grace period, hide their posts unless the viewer is the author?
    -- Actually, let's check if we should allow authors to see their own during grace. Yes.
    -- But for everyone else, they are hidden.
    and (
      p_post.author_id = viewer
      or not exists (
        select 1 from profile p 
        where p.id = p_post.author_id 
          and p.deletion_requested_at is not null
          and p.deletion_requested_at > now() - interval '30 days'
      )
    )
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

-- Note: The implementation above replaces the whole function in the DB.
-- In Supabase migrations, we usually just provide the new definition.
