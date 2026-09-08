-- Peak — feed rows need the author's public identity to render a post card.
-- `feed_latest` now returns each post plus its author's handle/domain/display
-- name/avatar and the viewer's own reaction + repost state, in one round trip.

drop function if exists feed_latest(timestamptz, int);

create or replace function feed_latest(
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
  author_avatar_path text,
  author_is_teen boolean,
  reaction_count bigint,
  reply_count bigint,
  repost_count bigint,
  viewer_reacted boolean,
  viewer_reposted boolean
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
    exists (select 1 from repost rp where rp.post_id = p.id and rp.actor_id = auth.uid())
  from post p
  join profile a on a.id = p.author_id
  where p.created_at < p_before
    and p.deleted_at is null
    and p.reply_to is null
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

-- Toggle helpers so the client doesn't hand-roll insert/delete + RLS races.
create or replace function toggle_reaction(p_post_id uuid, p_kind reaction_kind default 'like')
returns boolean  -- true = now reacted, false = removed
language plpgsql as $$
begin
  if exists (select 1 from reaction where post_id = p_post_id and actor_id = auth.uid()) then
    delete from reaction where post_id = p_post_id and actor_id = auth.uid();
    return false;
  end if;
  insert into reaction (post_id, actor_id, kind) values (p_post_id, auth.uid(), p_kind);
  return true;
end;
$$;

create or replace function toggle_repost(p_post_id uuid)
returns boolean
language plpgsql as $$
begin
  if exists (select 1 from repost where post_id = p_post_id and actor_id = auth.uid()) then
    delete from repost where post_id = p_post_id and actor_id = auth.uid();
    return false;
  end if;
  insert into repost (post_id, actor_id) values (p_post_id, auth.uid());
  return true;
end;
$$;
