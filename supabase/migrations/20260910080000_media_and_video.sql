-- Peak — media posters + the video destination ("Media" tab).
--
-- 1. post_media gains poster_path (a video's thumbnail frame, produced by the
--    local media server). post_media_json carries it to the app.
-- 2. videos_browse(): public top-level posts that have a video attachment,
--    newest-first or full-text-ranked when a query is given. Backs the Media
--    tab's browse + search. Same row shape as feed_local so the app reuses
--    FeedPost.fromMap.

alter table post_media add column poster_path text;

create or replace function post_media_json(p_post_id uuid) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'kind', m.kind,
        'storage_path', m.storage_path,
        'poster_path', m.poster_path,
        'alt_text', m.alt_text,
        'width', m.width,
        'height', m.height,
        'duration_ms', m.duration_ms
      ) order by m.sort_order
    ),
    '[]'::jsonb
  )
  from post_media m
  where m.post_id = p_post_id;
$$;

create or replace function videos_browse(
  p_query text default '',
  p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, reason text
)
language sql stable set search_path = public as $$
  with q as (
    select nullif(btrim(p_query), '') as raw,
           case when char_length(btrim(p_query)) >= 2
                then websearch_to_tsquery('english', p_query) end as ts
  )
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
    'Video'::text
  from post p
  join profile a on a.id = p.author_id
  cross join q
  where p.deleted_at is null
    and p.reply_to is null
    and p.visibility = 'public'
    and exists (select 1 from post_media pm
                where pm.post_id = p.id and pm.kind = 'video')
    and (q.raw is null or (q.ts is not null and p.search_vector @@ q.ts))
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by
    case when q.ts is not null then ts_rank(p.search_vector, q.ts) end desc nulls last,
    p.created_at desc
  limit least(p_limit, 60);
$$;

revoke all on function videos_browse(text, int) from public, anon;
grant execute on function videos_browse(text, int) to authenticated;
