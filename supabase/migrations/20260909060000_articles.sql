-- Peak — Phase 3: long-form articles.
--
-- An article is just a post: it gets replies, reactions, reposts, circle
-- visibility, the feed and threads for free. It adds a title and a much
-- larger body, and renders on its own page instead of inline.

alter table post add column title text check (char_length(title) <= 200);
alter table post add column long_form boolean not null default false;

-- widen the body limit for long-form; keep short posts tight
alter table post drop constraint post_body_check;
alter table post add constraint post_body_check check (
  char_length(body) <= case when long_form then 100000 else 5000 end
);

-- an article must have a title
alter table post add constraint post_article_needs_title check (
  not long_form or (title is not null and char_length(btrim(title)) > 0)
);

-- ── the post RPCs now carry title + long_form ─────────────────────────────
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
  title text, long_form boolean
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
    p.title, p.long_form
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

drop function if exists posts_by(uuid, timestamptz, int);
create or replace function posts_by(
  p_author uuid, p_before timestamptz default now(), p_limit int default 30
)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean
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
    p.title, p.long_form
  from post p
  join profile a on a.id = p.author_id
  where p.author_id = p_author
    and p.deleted_at is null
    and p.reply_to is null
    and p.created_at < p_before
    and can_view_post(p, auth.uid())
  order by p.created_at desc
  limit least(p_limit, 100);
$$;

drop function if exists post_thread(uuid);
create or replace function post_thread(p_root uuid)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  reply_to uuid, depth int,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_root post;
  v_viewer uuid := auth.uid();
begin
  select p.* into v_root from post p where p.id = p_root;
  if v_root.id is null or v_root.deleted_at is not null then
    return;
  end if;
  if not can_view_post(v_root, v_viewer) then
    return;
  end if;

  return query
  with recursive tree as (
    select p.*, 0 as depth
    from post p
    where p.id = p_root
    union all
    select c.*, tree.depth + 1
    from post c
    join tree on c.reply_to = tree.id
    where c.deleted_at is null and tree.depth < 4
  )
  select
    t.id, t.body, t.content_warning, t.is_sensitive, t.visibility,
    t.created_at, t.edited_at, t.reply_to, t.depth,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = t.id),
    (select count(*) from post pr where pr.reply_to = t.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = t.id),
    exists (select 1 from reaction r where r.post_id = t.id and r.actor_id = v_viewer),
    exists (select 1 from repost rp where rp.post_id = t.id and rp.actor_id = v_viewer),
    post_media_json(t.id),
    t.title, t.long_form
  from tree t
  join profile a on a.id = t.author_id
  where not blocked_between(v_viewer, t.author_id)
    and not exists (
      select 1 from mute mu
      where mu.muter_id = v_viewer and mu.muted_id = t.author_id
        and (mu.expires_at is null or mu.expires_at > now())
    )
  order by t.depth, t.created_at;
end;
$$;
