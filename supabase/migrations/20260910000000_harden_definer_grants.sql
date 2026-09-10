-- Peak — lock down SECURITY DEFINER functions that mutate data or forge
-- records and have no internal permission check. Surfaced by the hosted
-- Supabase security advisor (lints 0028/0029).
--
-- Trigger functions and internal helpers (_mod_log) are only ever reached via
-- triggers or from other SECURITY DEFINER functions — which run as the owner
-- and keep EXECUTE regardless — so revoking direct EXECUTE is safe.
--
-- Read-only predicates used inside RLS policies (can_view_post, blocked_between,
-- is_community_member, can_view_community, story_visible_to, modmail_can_see,
-- community_can_moderate, community_role_of, is_staff, can_post_in_channel,
-- can_manage_event) MUST stay executable by `authenticated`: RLS evaluates them
-- as the querying user, so they are intentionally left alone.

revoke all on function _mod_log(uuid, community_mod_action, uuid, uuid, text, text)
  from public, authenticated, anon;
revoke all on function purge_due_accounts()         from public, authenticated, anon;
revoke all on function purge_expired_deletions()    from public, authenticated, anon;
revoke all on function purge_expired_stories()      from public, authenticated, anon;

revoke all on function set_updated_at()             from public, authenticated, anon;
revoke all on function enforce_teen_defaults()      from public, authenticated, anon;
revoke all on function stamp_edited_at()            from public, authenticated, anon;
revoke all on function sync_account_kind()          from public, authenticated, anon;
revoke all on function bump_conversation_activity() from public, authenticated, anon;
revoke all on function drop_follows_on_block()      from public, authenticated, anon;
revoke all on function post_default_channel()       from public, authenticated, anon;
