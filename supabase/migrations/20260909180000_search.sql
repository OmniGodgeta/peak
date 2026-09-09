-- Peak — Phase 5: search.
--
-- Full-text search over posts (title + body), plus people and communities, in
-- one ranked list. Post visibility still goes through can_view_post, so a
-- search never leaks anything the caller couldn't already see.

alter table post add column search_vector tsvector
  generated always as (
    to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))
  ) stored;

create index post_search_idx on post using gin (search_vector)
  where deleted_at is null and reply_to is null;

-- ── posts ─────────────────────────────────────────────────────────────
create or replace function search_posts(p_query text, p_limit int default 20)
returns table (
  id uuid, body text, title text, created_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text,
  community_slug citext, rank real
)
language sql stable security definer set search_path = public as $$
  with q as (select websearch_to_tsquery('english', p_query) as ts)
  select
    p.id, p.body, p.title, p.created_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    c.slug,
    ts_rank(p.search_vector, q.ts)
      * (1.0 / (1 + extract(epoch from now() - p.created_at) / 2592000))::real
  from post p
  join profile a on a.id = p.author_id
  left join community c on c.id = p.community_id
  cross join q
  where char_length(btrim(p_query)) >= 2
    and q.ts is not null
    and p.search_vector @@ q.ts
    and p.deleted_at is null
    and p.reply_to is null
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by 11 desc
  limit least(p_limit, 50);
$$;

-- ── everything, in one ranked list ────────────────────────────────────
create or replace function search_all(p_query text, p_limit int default 8)
returns table (
  kind text, id uuid, title text, subtitle text,
  handle citext, avatar_path text, rank real
)
language sql stable security definer set search_path = public as $$
  with
  qs as (select btrim(p_query) as raw),
  people as (
    select 'person'::text, pr.id, pr.display_name, ('@' || pr.handle)::text,
           pr.handle, pr.avatar_path,
           (case when pr.handle ilike (select raw from qs) || '%' then 1.0
                 else 0.6 end)::real
    from profile pr, qs
    where char_length(qs.raw) >= 2
      and pr.is_discoverable
      and pr.account_kind = 'adult'
      and pr.deletion_requested_at is null
      and not blocked_between(auth.uid(), pr.id)
      and (pr.handle ilike '%' || qs.raw || '%'
           or pr.display_name ilike '%' || qs.raw || '%')
    limit p_limit
  ),
  comms as (
    select 'community'::text, c.id, c.name, c.description,
           c.slug, null::text, (0.8)::real
    from community c, qs
    where char_length(qs.raw) >= 2
      and c.is_listed and c.join_policy <> 'invite' and not c.is_nsfw
      and (c.name ilike '%' || qs.raw || '%'
           or c.slug ilike qs.raw || '%'
           or lower(qs.raw) = any (c.topics))
    limit p_limit
  ),
  posts as (
    select 'post'::text, sp.id,
           coalesce(nullif(sp.title, ''), left(sp.body, 100)),
           ('@' || sp.author_handle
             || case when sp.community_slug is not null
                     then ' · c/' || sp.community_slug else '' end)::text,
           sp.author_handle, sp.author_avatar_path, sp.rank
    from search_posts(p_query, p_limit) sp
  )
  select * from people
  union all select * from comms
  union all select * from posts
  order by 7 desc
  limit least(p_limit * 3, 60);
$$;

revoke all on function search_posts(text, int) from public;
revoke all on function search_all(text, int)   from public;
grant execute on function search_posts(text, int) to authenticated;
grant execute on function search_all(text, int)   to authenticated;
