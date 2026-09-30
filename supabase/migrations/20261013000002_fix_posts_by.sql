-- posts_by regressed in 20261008000001_fix_remaining_feed_rpcs:
--   * its parameter was renamed p_author -> p_profile_id, but the app calls
--     posts_by(p_author => ...), so PostgREST answered PGRST202 "could not
--     find the function" and every profile's post list failed to load;
--   * is_pinned became a hardcoded false (pins never showed; pgTAP test
--     "pin_post marks the post pinned in posts_by" has failed in CI since);
--   * replies started appearing in the profile list (reply_to filter lost).
-- Restore the original contract and keep what that migration added
-- (author_is_verified, the block check).

drop function if exists posts_by(uuid, timestamptz, int);
create function posts_by(
  p_author uuid, p_before timestamptz default now(), p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, is_pinned boolean, author_is_verified boolean
)
language sql
stable
security definer
set search_path = public
as $$
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
    exists (select 1 from profile_pin pp
            where pp.owner_id = p_author and pp.post_id = p.id),
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_author
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

revoke all on function posts_by(uuid, timestamptz, int) from public, anon;
grant execute on function posts_by(uuid, timestamptz, int) to authenticated;
