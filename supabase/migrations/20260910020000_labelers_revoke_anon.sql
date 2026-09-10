-- Applied to the hosted project as a follow-up: the initial labelers migration
-- there only revoked EXECUTE from `public`, and Supabase's default grants leave
-- `anon` with an implicit EXECUTE. Kept as its own migration so the repo's
-- migration history matches hosted. (The v1 file above now also revokes `anon`,
-- so on a fresh `db reset` this is a harmless no-op.)
revoke all on function create_labeler(text, text, boolean)         from anon;
revoke all on function set_labeler_labels(uuid, jsonb)             from anon;
revoke all on function apply_content_label(uuid, uuid, text, text) from anon;
revoke all on function remove_content_label(uuid, uuid)            from anon;
revoke all on function subscribe_labeler(uuid)                     from anon;
revoke all on function unsubscribe_labeler(uuid)                   from anon;
revoke all on function my_labelers()                              from anon;
revoke all on function labelers_browse(text, int)                  from anon;
revoke all on function labeler_labels(uuid)                        from anon;
revoke all on function post_labels_for_me(uuid[])                  from anon;
