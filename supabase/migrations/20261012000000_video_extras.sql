-- Chapters + captions for the watch page, and cleanup of replaced thumbnails.
--
-- 1. video_extras(p_post_id): the post's first video's media id, chapters and
--    captions in one call. Security invoker, so the post_chapters /
--    post_subtitles select policies (which follow can_view_post) still apply.
-- 2. A replaced poster that lived in the post-media bucket is queued in
--    media_pending_delete, the same queue the 30-day purge feeds, so the old
--    image doesn't sit in storage forever. Media-server URLs are skipped.

create or replace function video_extras(p_post_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select jsonb_build_object(
    'media_id', m.id,
    'chapters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', c.label, 'start_ms', c.start_ms, 'end_ms', c.end_ms)
             order by c.start_ms)
      from post_chapters c
      where c.media_id = m.id
    ), '[]'::jsonb),
    'captions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'language', s.language, 'text', s.text,
               'start_ms', s.start_ms, 'end_ms', s.end_ms)
             order by s.start_ms)
      from post_subtitles s
      where s.media_id = m.id
    ), '[]'::jsonb)
  )
  from post_media m
  join post p on p.id = m.post_id
  where m.post_id = p_post_id
    and m.kind = 'video'
    and can_view_post(p, auth.uid())
  order by m.id
  limit 1;
$$;

revoke all on function video_extras(uuid) from public, anon, authenticated;
grant execute on function video_extras(uuid) to authenticated;

create or replace function queue_replaced_poster()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.poster_path is not null
     and old.poster_path is distinct from new.poster_path
     and old.poster_path not like 'http://%'
     and old.poster_path not like 'https://%' then
    -- Only files in the post author's own folder (<uid>/...), so pointing a
    -- poster at someone else's object and swapping it can't delete theirs.
    insert into media_pending_delete (bucket_id, object_name)
    select 'post-media', old.poster_path
    from post p
    where p.id = new.post_id
      and old.poster_path like p.author_id::text || '/%'
    on conflict do nothing;
  end if;
  return new;
end;
$$;

revoke all on function queue_replaced_poster() from public, anon, authenticated;

drop trigger if exists post_media_poster_replaced on post_media;
create trigger post_media_poster_replaced
  after update of poster_path on post_media
  for each row execute function queue_replaced_poster();
