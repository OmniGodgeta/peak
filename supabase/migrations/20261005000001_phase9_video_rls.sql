-- Chapters and subtitles follow the post's audience. The first Phase 9
-- policies allowed anyone to read them.

drop policy if exists "Chapters are viewable by everyone" on post_chapters;
drop policy if exists "Subtitles are viewable by everyone" on post_subtitles;

create policy post_chapters_select on post_chapters
  for select using (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_chapters.media_id
        and can_view_post(p, auth.uid())
    )
  );

create policy post_chapters_write on post_chapters
  for all using (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_chapters.media_id
        and p.author_id = auth.uid()
    )
  ) with check (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_chapters.media_id
        and p.author_id = auth.uid()
    )
  );

create policy post_subtitles_select on post_subtitles
  for select using (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_subtitles.media_id
        and can_view_post(p, auth.uid())
    )
  );

create policy post_subtitles_write on post_subtitles
  for all using (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_subtitles.media_id
        and p.author_id = auth.uid()
    )
  ) with check (
    exists (
      select 1
      from post_media m
      join post p on p.id = m.post_id
      where m.id = post_subtitles.media_id
        and p.author_id = auth.uid()
    )
  );

revoke all on function get_user_videos(uuid, integer) from public;
grant execute on function get_user_videos(uuid, integer) to authenticated;
