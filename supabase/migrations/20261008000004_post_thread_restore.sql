-- The verified-flag rewrite of post_thread dropped reply_to and then
-- failed at runtime. Restore the previous thread shape and append
-- author_is_verified.

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
  title text, long_form boolean,
  author_is_verified boolean
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
    t.title, t.long_form,
    is_verified_person(a.id)
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

grant execute on function post_thread(uuid) to authenticated;
