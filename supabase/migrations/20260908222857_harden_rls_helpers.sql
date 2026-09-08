-- Peak — the helper functions used *inside* RLS policies must see the whole
-- graph, not just the calling user's RLS-visible slice.
--
-- The bug: `blocked_between()` and `can_view_post()` query `block`, `follow`,
-- `mention`, `circle_member`, `post_audience` — all of which have their own RLS.
-- Run with the caller's rights they return wrong answers, e.g.:
--   * B blocks A. A reads A's own `block` rows only, so `blocked_between(A,B)`
--     is false for A → A can still see B's profile. Wrong.
--   * B posts to a circle containing A. A can't see `circle_member` rows for a
--     circle A doesn't own, so `can_view_post` says "not a member" → the post
--     is hidden from its intended audience. Wrong.
--
-- Fix: these are trusted, side-effect-free predicates. Make them SECURITY
-- DEFINER with a pinned search_path so they evaluate against the full tables.
-- The policies that call them still gate what each user can actually read.
--
-- Also: `drop_follows_on_block()` (trigger) deletes follow edges in both
-- directions; under caller rights the `follow_delete` policy (follower only)
-- silently drops half the delete. Same fix.

create or replace function blocked_between(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from block
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

create or replace function can_view_post(p_post post, viewer uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_post.deleted_at is null
    and not blocked_between(viewer, p_post.author_id)
    and (
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
            select 1
            from post_audience pa
            join circle_member cm on cm.circle_id = pa.circle_id
            where pa.post_id = p_post.id and cm.member_id = viewer
          ))
      or (p_post.visibility = 'circles'
          and exists (
            select 1 from post_audience pa
            join circle c on c.id = pa.circle_id
            where pa.post_id = p_post.id and c.is_public
          ))
    );
$$;

create or replace function drop_follows_on_block() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from follow
   where (follower_id = new.blocker_id and followee_id = new.blocked_id)
      or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end;
$$;
