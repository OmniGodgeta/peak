-- post_thread failed: `id` in the root select was ambiguous with the
-- OUT column of the same name. Qualify the table column.

create or replace function post_thread(p_root uuid)
returns table (
  id uuid, body text, content_warning text, is_sensitive boolean,
  visibility post_visibility, created_at timestamptz, edited_at timestamptz,
  author_id uuid, author_handle citext, author_domain text,
  author_display_name text, author_avatar_path text, author_is_teen boolean,
  reaction_count bigint, reply_count bigint, repost_count bigint,
  viewer_reacted boolean, viewer_reposted boolean, media jsonb,
  title text, long_form boolean, depth int,
  author_is_verified boolean
)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
  with recursive thread as (
    select p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
           p.created_at, p.edited_at, p.author_id, p.title, p.long_form,
           p.channel_id, p.community_id, 0 as depth
    from post p
    where p.id = p_root
    union all
    select p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
           p.created_at, p.edited_at, p.author_id, p.title, p.long_form,
           p.channel_id, p.community_id, t.depth + 1
    from post p
    join thread t on p.reply_to = t.id
    where p.deleted_at is null
  )
  select
    t.id, t.body, t.content_warning, t.is_sensitive, t.visibility,
    t.created_at, t.edited_at,
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.account_kind = 'teen'),
    (select count(*) from reaction r where r.post_id = t.id),
    (select count(*) from post pr where pr.reply_to = t.id and pr.deleted_at is null),
    (select count(*) from repost rp where rp.post_id = t.id),
    exists (select 1 from reaction r where r.post_id = t.id and r.actor_id = auth.uid()),
    exists (select 1 from repost rp where rp.post_id = t.id and rp.actor_id = auth.uid()),
    post_media_json(t.id),
    t.title, t.long_form, t.depth,
    is_verified_person(a.id)
  from thread t
  join profile a on a.id = t.author_id
  where can_view_post((select p.* from post p where p.id = t.id), auth.uid())
  order by t.depth, t.created_at;
end;
$$;

grant execute on function post_thread(uuid) to authenticated;
