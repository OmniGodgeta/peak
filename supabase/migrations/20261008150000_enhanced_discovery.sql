-- Peak — Phase 5.1: Advanced Search & Discovery.
-- Enhances search with language filtering and introduces saved searches functionality.

-- 1. Saved Searches Table
create table saved_searches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profile (id) on delete cascade,
  query text not null check (char_length(trim(query)) >= 2),
  kind text not null check (kind in ('post', 'person', 'community')),
  created_at timestamptz not null default now(),
  unique (user_id, query, kind)
);

alter table saved_searches enable row level security;

create policy saved_searches_select on saved_searches for select using (auth.uid() = user_id);
create policy saved_searches_insert on saved_searches for insert with check (auth.uid() = user_id);
create policy saved_searches_delete on saved_searches for delete using (auth.uid() = user_id);

-- 2. Enhanced Search Functions

-- Adding p_lang changes the signature, so the old functions have to go first.
drop function if exists search_posts(text, int);
drop function if exists search_all(text, int);

create or replace function search_posts(p_query text, p_limit int default 20, p_lang text default null)
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
    and (p_lang is null or p.language_tag = p_lang)
    and can_view_post(p, auth.uid())
    and not blocked_between(auth.uid(), a.id)
  order by 11 desc
  limit least(p_limit, 50);
$$;

-- Update search_all to support p_lang
create or replace function search_all(p_query text, p_limit int default 8, p_lang text default null)
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
    from search_posts(p_query, p_limit, p_lang) sp -- Passed language filter
  )
  select * from people
  union all select * from comms
  union all select * from posts
  order by 7 desc
  limit least(p_limit * 3, 60);
$$;

-- 3. Saved Search RPCs
create or replace function get_saved_searches()
returns setof saved_searches
language sql stable security definer set search_path = public as $$
  select * from saved_searches where user_id = auth.uid() order by created_at desc;
$$;

create or replace function save_search(p_query text, p_kind text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into saved_searches (user_id, query, kind)
  values (auth.uid(), btrim(p_query), p_kind)
  on conflict (user_id, query, kind) do nothing;
end;
$$;

create or replace function delete_saved_search(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from saved_searches where id = p_id and user_id = auth.uid();
end;
$$;

revoke all on function search_posts(text, int, text) from public;
revoke all on function search_all(text, int, text) from public;
grant execute on function search_posts(text, int, text) to authenticated;
grant execute on function search_all(text, int, text) to authenticated;

revoke all on function get_saved_searches() from public;
revoke all on function save_search(text, text) from public;
revoke all on function delete_saved_search(uuid) from public;
grant execute on function get_saved_searches() to authenticated;
grant execute on function save_search(text, text) to authenticated;
grant execute on function delete_saved_search(uuid) to authenticated;
