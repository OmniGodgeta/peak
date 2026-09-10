-- Peak — Phase 5: interests + People-you-may-know.
--
-- Suggestions come ONLY from the graph you built: people your follows follow,
-- people in your communities, and communities matching your stated interests.
-- Never from contacts, location, or behavioural tracking.

create table profile_interest (
  profile_id uuid not null references profile (id) on delete cascade,
  topic      text not null check (topic ~ '^[a-z0-9][a-z0-9 _-]{0,38}$'),
  primary key (profile_id, topic)
);

alter table profile_interest enable row level security;
create policy profile_interest_own on profile_interest for all
  using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create or replace function set_my_interests(p_topics text[])
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from profile_interest where profile_id = auth.uid();
  insert into profile_interest (profile_id, topic)
  select auth.uid(), lower(btrim(t))
  from unnest(coalesce(p_topics, '{}')) as t
  where btrim(t) <> '' and lower(btrim(t)) ~ '^[a-z0-9][a-z0-9 _-]{0,38}$'
  on conflict do nothing;
end;
$$;

create or replace function my_interests()
returns table (topic text)
language sql stable security definer set search_path = public as $$
  select topic from profile_interest where profile_id = auth.uid() order by topic;
$$;

-- ── People you may know ───────────────────────────────────────────────
create or replace function people_you_may_know(p_limit int default 20)
returns table (
  id uuid, handle citext, domain text, display_name text, avatar_path text,
  is_teen boolean, mutuals int, reason text
)
language sql stable security definer set search_path = public as $$
  with already as (
    select followee_id as id from follow where follower_id = auth.uid()
    union select auth.uid()
    union select blocked_id from block where blocker_id = auth.uid()
    union select blocker_id from block where blocked_id = auth.uid()
  ),
  fof as (
    select f2.followee_id as pid,
           count(*)::int as via,
           (array_agg(fa.handle order by fa.handle))[1] as via_handle,
           null::citext as via_slug
    from follow f1
    join follow f2 on f2.follower_id = f1.followee_id
    join profile fa on fa.id = f1.followee_id
    where f1.follower_id = auth.uid()
      and f2.followee_id not in (select id from already)
    group by f2.followee_id
  ),
  comm as (
    select cm2.member_id as pid,
           count(distinct cm2.community_id)::int as via,
           null::citext as via_handle,
           (array_agg(c.slug order by c.slug))[1] as via_slug
    from community_member cm1
    join community_member cm2 on cm2.community_id = cm1.community_id
    join community c on c.id = cm2.community_id
    where cm1.member_id = auth.uid() and cm1.state = 'active'
      and cm2.state = 'active'
      and cm2.member_id not in (select id from already)
    group by cm2.member_id
  ),
  merged as (
    select pid, sum(via)::int as score,
           max(via_handle) as via_handle, max(via_slug) as via_slug
    from (select * from fof union all select * from comm) u
    group by pid
  )
  select
    p.id, p.handle, p.domain, p.display_name, p.avatar_path,
    (p.account_kind = 'teen'), m.score,
    case
      when m.via_handle is not null then 'Followed by @' || m.via_handle
      when m.via_slug is not null then 'In c/' || m.via_slug || ' with you'
      else 'Suggested for you'
    end
  from merged m
  join profile p on p.id = m.pid
  where p.is_discoverable
    and p.account_kind = 'adult'
    and p.deletion_requested_at is null
  order by m.score desc, p.handle
  limit least(p_limit, 40);
$$;

-- ── Communities for you ───────────────────────────────────────────────
create or replace function suggested_communities(p_limit int default 12)
returns table (
  id uuid, slug citext, name text, description text, topics text[],
  is_nsfw boolean, member_count int, match_reason text
)
language sql stable security definer set search_path = public as $$
  with my_topics as (
    select topic from profile_interest where profile_id = auth.uid()
    union
    select t from community c2
    join community_member cm on cm.community_id = c2.id
      and cm.member_id = auth.uid() and cm.state = 'active',
      lateral unnest(c2.topics) as t
  ),
  mine as (
    select community_id from community_member
    where member_id = auth.uid()
  )
  select
    c.id, c.slug, c.name, c.description, c.topics, c.is_nsfw,
    (select count(*)::int from community_member cm
     where cm.community_id = c.id and cm.state = 'active'),
    'Matches ' || (
      select string_agg(t, ', ') from (
        select distinct t from unnest(c.topics) as t
        where t in (select topic from my_topics)
        limit 3
      ) s
    )
  from community c
  where c.is_listed and c.join_policy <> 'invite' and not c.is_nsfw
    and c.id not in (select community_id from mine)
    and exists (
      select 1 from unnest(c.topics) as t
      where t in (select topic from my_topics)
    )
  order by (select count(*) from community_member cm
            where cm.community_id = c.id and cm.state = 'active') desc
  limit least(p_limit, 30);
$$;

revoke all on function set_my_interests(text[])       from public;
revoke all on function my_interests()                 from public;
revoke all on function people_you_may_know(int)       from public;
revoke all on function suggested_communities(int)     from public;
grant execute on function set_my_interests(text[])     to authenticated;
grant execute on function my_interests()               to authenticated;
grant execute on function people_you_may_know(int)     to authenticated;
grant execute on function suggested_communities(int)   to authenticated;
