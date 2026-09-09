-- Peak — Phase 4: richer community discovery.
--
-- communities_browse gains a topic filter, a sort (active / new / large), and
-- an NSFW opt-in, plus activity signal (last post, posts in the last 7 days).
-- community_topics lists the topic tags in use for the filter chips.

drop function if exists communities_browse(text, int);
create or replace function communities_browse(
  p_query text default '',
  p_topic text default null,
  p_sort text default 'active',
  p_include_nsfw boolean default false,
  p_limit int default 40
)
returns table (
  id uuid, slug citext, name text, description text, topics text[],
  is_nsfw boolean, member_count int, is_member boolean,
  last_activity_at timestamptz, posts_7d int
)
language sql stable security definer set search_path = public as $$
  with base as (
    select
      c.id, c.slug, c.name, c.description, c.topics, c.is_nsfw, c.created_at,
      (select count(*)::int from community_member cm
       where cm.community_id = c.id and cm.state = 'active') as member_count,
      is_community_member(c.id, auth.uid()) as is_member,
      (select max(p.created_at) from post p
       where p.community_id = c.id and p.deleted_at is null) as last_activity_at,
      (select count(*)::int from post p
       where p.community_id = c.id and p.deleted_at is null
         and p.created_at > now() - interval '7 days') as posts_7d
    from community c
    where c.is_listed
      and c.join_policy <> 'invite'
      and (p_include_nsfw or not c.is_nsfw)
      and (
        btrim(p_query) = ''
        or c.name ilike '%' || btrim(p_query) || '%'
        or c.slug ilike btrim(p_query) || '%'
        or btrim(lower(p_query)) = any (c.topics)
      )
      and (p_topic is null or btrim(lower(p_topic)) = any (c.topics))
  )
  select
    id, slug, name, description, topics, is_nsfw, member_count, is_member,
    last_activity_at, posts_7d
  from base
  order by
    case when p_sort = 'new'   then created_at end desc nulls last,
    case when p_sort = 'large' then member_count end desc nulls last,
    case when p_sort not in ('new', 'large')
         then coalesce(last_activity_at, to_timestamp(0)) end desc,
    member_count desc, created_at desc
  limit least(p_limit, 60);
$$;

-- the topic tags in use across listed communities, most common first
create or replace function community_topics(p_limit int default 40)
returns table (topic text, community_count int)
language sql stable security definer set search_path = public as $$
  select t.topic, count(*)::int
  from community c, lateral unnest(c.topics) as t(topic)
  where c.is_listed and c.join_policy <> 'invite'
    and (not c.is_nsfw)
  group by t.topic
  order by count(*) desc, t.topic
  limit least(p_limit, 100);
$$;

revoke all on function communities_browse(text, text, text, boolean, int) from public;
revoke all on function community_topics(int)                              from public;
grant execute on function communities_browse(text, text, text, boolean, int) to authenticated;
grant execute on function community_topics(int)                              to authenticated;
