-- Peak — media on posts and replies (photos + GIFs now; video is Phase 3/9).
--
-- Storage: a `post-media` bucket. Public-read for now — media lives at an
-- unguessable path (`<author>/<uuid>.<ext>`) and the post_media *row* is still
-- RLS-gated by can_view_post. Phase 3 hardens non-public posts to signed URLs
-- gated by visibility; tracked in docs/ROADMAP.md.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'post-media', 'post-media', true,
  26214400,  -- 25 MB/object
  array['image/jpeg','image/png','image/webp','image/gif','image/avif']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Upload/update/delete only within your own top-level folder (folder name = uid).
create policy "post-media: read"
  on storage.objects for select
  using (bucket_id = 'post-media');

create policy "post-media: write own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'post-media'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "post-media: update own"
  on storage.objects for update to authenticated
  using (bucket_id = 'post-media' and owner = auth.uid());

create policy "post-media: delete own"
  on storage.objects for delete to authenticated
  using (bucket_id = 'post-media' and owner = auth.uid());

-- ── Include media in the feed / profile RPCs ────────────────────────────────
-- Small helper so the three feed-shaped functions agree on the media shape.
create or replace function post_media_json(p_post_id uuid) returns jsonb
language sql stable as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'kind', m.kind,
        'storage_path', m.storage_path,
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
  viewer_reacted boolean, viewer_reposted boolean, media jsonb
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
    post_media_json(p.id)
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
  viewer_reacted boolean, viewer_reposted boolean, media jsonb
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
    post_media_json(p.id)
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

-- ── post_thread: a root post + its reply tree (up to 4 levels) ──────────────
-- Thread visibility model (Phase 1): if you can see the root, you can see the
-- whole thread, minus replies from accounts blocked in either direction and
-- minus muted authors. SECURITY DEFINER because replies inherit the root's
-- visibility *value* without their own audience rows, so per-row RLS on `post`
-- would hide them. Phase 4 revisits this with real thread permissions.
create or replace function post_thread(p_root uuid)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  reply_to uuid, depth int,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb
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
    return;  -- can't see the root => can't see the thread
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
    post_media_json(t.id)
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
