-- Peak — Phase 5: the Friends-first feed variant + "why am I seeing this?".
--
-- feed_latest keeps its meaning (everyone you follow, newest first) and gains a
-- `reason` string. feed_friends is the same but restricted to people who follow
-- you back — a calmer feed of your actual connections.

drop function if exists feed_latest(timestamptz, int);
create or replace function feed_latest(
  p_before timestamptz default now(),
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
language sql stable as $$
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
    case
      when p.author_id = auth.uid() then 'Your post'
      when exists (select 1 from follow fb
                   where fb.follower_id = a.id and fb.followee_id = auth.uid())
        then 'You and @' || a.handle || ' follow each other'
      else 'You follow @' || a.handle
    end
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and (
      p.author_id = auth.uid()
      or exists (select 1 from follow f
                 where f.follower_id = auth.uid() and f.followee_id = p.author_id)
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

create or replace function feed_friends(
  p_before timestamptz default now(),
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
language sql stable as $$
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
    case when p.author_id = auth.uid() then 'Your post'
         else 'You and @' || a.handle || ' follow each other' end
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
    and p.community_id is null
    and (
      p.author_id = auth.uid()
      or (
        exists (select 1 from follow f
                where f.follower_id = auth.uid() and f.followee_id = p.author_id)
        and exists (select 1 from follow fb
                    where fb.follower_id = p.author_id and fb.followee_id = auth.uid())
      )
    )
    and can_view_post(p, auth.uid())
    and not exists (select 1 from mute mu
                    where mu.muter_id = auth.uid() and mu.muted_id = p.author_id
                      and (mu.expires_at is null or mu.expires_at > now()))
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

grant execute on function feed_latest(timestamptz, int)  to authenticated;
grant execute on function feed_friends(timestamptz, int)  to authenticated;
