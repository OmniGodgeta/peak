-- Close the rest of Phase 5 that the app can feel:
--   * follower fan-out written when a public post is created
--   * Latest also reads that index (hybrid with the live follow join)
--   * For You (recommend_posts_for_user) from spaces you joined and interests
--   * a verified-person flag on Latest and For You rows
--
-- Global rank_score stays a recency decay. Likes, reposts, replies, and
-- follower counts are not part of the order.

create or replace function fanout_post_to_followers()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reply_to is not null
     or new.deleted_at is not null
     or new.visibility <> 'public' then
    return new;
  end if;
  insert into fanout_feed_index (user_id, post_id, priority)
  select f.follower_id, new.id, 5
  from follow f
  where f.followee_id = new.author_id
  on conflict (user_id, post_id) do nothing;
  return new;
end;
$$;

drop trigger if exists fanout_post_to_followers on post;
create trigger fanout_post_to_followers
  after insert on post
  for each row execute function fanout_post_to_followers();

revoke all on function fanout_post_to_followers() from public, anon, authenticated;

insert into fanout_feed_index (user_id, post_id, priority)
select f.follower_id, p.id, 5
from post p
join follow f on f.followee_id = p.author_id
where p.deleted_at is null
  and p.reply_to is null
  and p.visibility = 'public'
on conflict (user_id, post_id) do nothing;

drop function if exists feed_latest(timestamptz, int);
drop function if exists feed_latest(int);

create function feed_latest(
  p_before timestamptz default now(),
  p_limit int default 30
)
returns table (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility post_visibility,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle citext,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to uuid,
    depth int,
    author_is_verified boolean
)
language sql stable set search_path = public as $$
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, a.handle, a.domain,
    a.display_name, (a.account_kind = 'teen'), a.avatar_path,
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    false,
    null::text, null::text, null::text, p.channel_id, null::text,
    case
      when p.author_id = auth.uid() then 'Your post'
      when exists (select 1 from follow fb
                   where fb.follower_id = a.id and fb.followee_id = auth.uid())
        then 'You and @' || a.handle || ' follow each other'
      when exists (select 1 from follow f
                   where f.follower_id = auth.uid() and f.followee_id = p.author_id)
        then 'You follow @' || a.handle
      when exists (select 1 from post_media pm
                   where pm.post_id = p.id and pm.kind = 'video')
        then 'Video on Peak'
      else 'On Peak'
    end,
    p.reply_to, 0,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and (
      (
        p.community_id is null
        and (
          p.author_id = auth.uid()
          or exists (select 1 from follow f
                     where f.follower_id = auth.uid() and f.followee_id = p.author_id)
          or exists (select 1 from fanout_feed_index fi
                     where fi.user_id = auth.uid() and fi.post_id = p.id)
        )
      )
      or (
        p.visibility = 'public'
        and exists (select 1 from post_media pm
                    where pm.post_id = p.id and pm.kind = 'video')
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

revoke all on function feed_latest(timestamptz, int) from public;
grant execute on function feed_latest(timestamptz, int) to authenticated;

create or replace function recommend_posts_for_user(p_limit int default 30)
returns table (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility post_visibility,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle citext,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to uuid,
    depth int,
    author_is_verified boolean
)
language sql stable set search_path = public as $$
  with interests as (
    select coalesce(array_agg(topic), '{}'::text[]) as topics
    from profile_interest
    where profile_id = auth.uid()
  )
  select
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, a.handle, a.domain,
    a.display_name, (a.account_kind = 'teen'), a.avatar_path,
    (select count(*) from reaction r where r.post_id = p.id),
    (select count(*) from post pr where pr.reply_to = p.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = p.id),
    exists (select 1 from reaction r where r.post_id = p.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid()),
    post_media_json(p.id),
    p.title, p.long_form,
    false,
    null::text, null::text, null::text, p.channel_id, null::text,
    case
      when exists (select 1 from post_media pm
                   where pm.post_id = p.id and pm.kind = 'video')
        then 'Video on Peak'
      when p.community_id is not null
           and exists (select 1 from community_member cm
                       where cm.community_id = p.community_id
                         and cm.member_id = auth.uid()
                         and cm.state = 'active')
        then 'In a space you joined'
      else 'Matches an interest'
    end,
    p.reply_to, 0,
    is_verified_person(a.id)
  from post p
  join profile a on a.id = p.author_id
  cross join interests i
  where p.deleted_at is null
    and p.reply_to is null
    and p.visibility = 'public'
    and p.author_id is distinct from auth.uid()
    and (
      exists (select 1 from post_media pm
              where pm.post_id = p.id and pm.kind = 'video')
      or (
        p.community_id is not null
        and exists (select 1 from community_member cm
                    where cm.community_id = p.community_id
                      and cm.member_id = auth.uid()
                      and cm.state = 'active')
      )
      or exists (
        select 1 from community c
        where c.id = p.community_id
          and c.topics && i.topics
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

revoke all on function recommend_posts_for_user(int) from public;
grant execute on function recommend_posts_for_user(int) to authenticated;
