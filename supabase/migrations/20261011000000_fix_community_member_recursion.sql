-- community_member_select's own USING clause queried community_member again
-- (as `me`) to check the viewer's membership - under RLS, that inner query
-- is itself subject to the same policy, which is genuine infinite
-- recursion. Postgres detects this and errors outright:
-- "infinite recursion detected in policy for relation community_member"
-- (SQLSTATE 42P17) - this broke recommend_posts_for_user (the For You feed),
-- which queries community_member directly rather than through a
-- security-definer helper. Present since the table was created
-- (20260909090000_communities.sql) - not something introduced recently.
--
-- Fixed by using the existing is_community_member() helper (already
-- `security definer`, so its internal query bypasses RLS instead of
-- re-triggering this same policy).

drop policy if exists community_member_select on community_member;

create policy community_member_select on community_member for select using (
  member_id = auth.uid()
  or is_community_member(community_id, auth.uid())
);
