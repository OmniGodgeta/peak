-- Peak — Phase 3: stories.
--
-- A story is a photo (+ optional caption) addressed to one or more of your
-- circles, visible for 24 hours. Deliberately unlike the incumbents: no
-- face-retouch filters, no streaks, no "seen at 11:04" pressure beyond a plain
-- viewer list for the author. Views are recorded but never gamified.

create table story (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid not null references profile (id) on delete cascade,
  persona_id  uuid not null references persona (id) on delete cascade,
  media_path  text not null,
  media_kind  media_kind not null default 'image',
  caption     text check (char_length(caption) <= 280),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '24 hours')
);
create index story_author_idx on story (author_id, expires_at);
create index story_active_idx on story (expires_at);

create table story_audience (
  story_id   uuid not null references story (id) on delete cascade,
  circle_id  uuid not null references circle (id) on delete cascade,
  primary key (story_id, circle_id)
);

create table story_view (
  story_id  uuid not null references story (id) on delete cascade,
  viewer_id uuid not null references profile (id) on delete cascade,
  seen_at   timestamptz not null default now(),
  primary key (story_id, viewer_id)
);

alter table story          enable row level security;
alter table story_audience enable row level security;
alter table story_view     enable row level security;

-- ── visibility helper ─────────────────────────────────────────────────────
-- SECURITY DEFINER so it can read story_audience / circle_member from inside a
-- policy (same pattern as can_view_post).
create or replace function story_visible_to(p_story story, p_viewer uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select
    p_story.author_id = p_viewer
    or (
      p_story.expires_at > now()
      and not blocked_between(p_viewer, p_story.author_id)
      and exists (
        select 1
        from story_audience sa
        join circle_member cm on cm.circle_id = sa.circle_id
        where sa.story_id = p_story.id and cm.member_id = p_viewer
      )
    );
$$;

create policy story_select on story for select using (story_visible_to(story, auth.uid()));
create policy story_insert on story for insert with check (author_id = auth.uid());
create policy story_delete on story for delete using (author_id = auth.uid());

create policy story_audience_rw on story_audience for all
  using (exists (select 1 from story s where s.id = story_id and s.author_id = auth.uid()))
  with check (exists (select 1 from story s where s.id = story_id and s.author_id = auth.uid()));

create policy story_view_insert on story_view for insert with check (viewer_id = auth.uid());
create policy story_view_select on story_view for select using (
  viewer_id = auth.uid()
  or exists (select 1 from story s where s.id = story_id and s.author_id = auth.uid())
);

-- ── post a story ──────────────────────────────────────────────────────────
create or replace function post_story(
  p_media_path text,
  p_caption text default null,
  p_circle_ids uuid[] default '{}'
)
returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_me      uuid := auth.uid();
  v_persona uuid;
  v_id      uuid;
  v_cid     uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  if coalesce(array_length(p_circle_ids, 1), 0) = 0 then
    raise exception 'a story needs at least one circle';
  end if;
  select id into v_persona from persona where account_id = v_me and is_default;

  insert into story (author_id, persona_id, media_path, caption)
  values (v_me, v_persona, p_media_path, nullif(btrim(p_caption), ''))
  returning id into v_id;

  foreach v_cid in array p_circle_ids loop
    if exists (select 1 from circle where id = v_cid and owner_id = v_me) then
      insert into story_audience (story_id, circle_id) values (v_id, v_cid);
    end if;
  end loop;

  return v_id;
end;
$$;

-- ── the tray: one entry per author with active, visible stories ───────────
create or replace function stories_tray()
returns table (
  author_id uuid,
  handle citext,
  domain text,
  display_name text,
  avatar_path text,
  is_self boolean,
  story_count int,
  has_unseen boolean,
  latest_at timestamptz
)
language sql stable security definer set search_path = public as $$
  with visible as (
    select s.*
    from story s
    where s.expires_at > now()
      and story_visible_to(s, auth.uid())
      and (
        s.author_id = auth.uid()
        or exists (select 1 from follow f
                   where f.follower_id = auth.uid() and f.followee_id = s.author_id)
      )
  )
  select
    a.id, a.handle, a.domain, a.display_name, a.avatar_path,
    (a.id = auth.uid()),
    count(*)::int,
    bool_or(not exists (
      select 1 from story_view sv
      where sv.story_id = v.id and sv.viewer_id = auth.uid()
    )),
    max(v.created_at)
  from visible v
  join profile a on a.id = v.author_id
  group by a.id, a.handle, a.domain, a.display_name, a.avatar_path
  -- your own tray entry first, then most-recently-updated
  order by (a.id = auth.uid()) desc, max(v.created_at) desc;
$$;

-- ── one author's stories, oldest first, with the viewer's seen state ─────
create or replace function story_thread(p_author uuid)
returns table (
  id uuid,
  media_path text,
  media_kind media_kind,
  caption text,
  created_at timestamptz,
  expires_at timestamptz,
  seen boolean,
  viewer_count int
)
language sql stable security definer set search_path = public as $$
  select
    s.id, s.media_path, s.media_kind, s.caption, s.created_at, s.expires_at,
    exists (select 1 from story_view sv
            where sv.story_id = s.id and sv.viewer_id = auth.uid()),
    case when s.author_id = auth.uid()
         then (select count(*)::int from story_view sv where sv.story_id = s.id)
         else 0 end
  from story s
  where s.author_id = p_author
    and s.expires_at > now()
    and story_visible_to(s, auth.uid())
  order by s.created_at;
$$;

create or replace function mark_story_seen(p_story_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_s story;
begin
  select * into v_s from story where id = p_story_id;
  if v_s.id is null or not story_visible_to(v_s, auth.uid()) then return; end if;
  if v_s.author_id = auth.uid() then return; end if;
  insert into story_view (story_id, viewer_id)
  values (p_story_id, auth.uid())
  on conflict do nothing;
end;
$$;

create or replace function story_viewers(p_story_id uuid)
returns table (
  handle citext,
  domain text,
  display_name text,
  avatar_path text,
  seen_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select p.handle, p.domain, p.display_name, p.avatar_path, sv.seen_at
  from story_view sv
  join profile p on p.id = sv.viewer_id
  where sv.story_id = p_story_id
    and exists (select 1 from story s
                where s.id = p_story_id and s.author_id = auth.uid())
  order by sv.seen_at desc;
$$;

create or replace function delete_story(p_story_id uuid)
returns void
language sql security invoker set search_path = public as $$
  delete from story where id = p_story_id and author_id = auth.uid();
$$;

-- cron: drop expired stories (ops schedules this, hourly)
create or replace function purge_expired_stories()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  with gone as (delete from story where expires_at < now() returning 1)
  select count(*) into v_n from gone;
  return v_n;
end;
$$;

revoke all on function post_story(text, text, uuid[])  from public;
revoke all on function stories_tray()                  from public;
revoke all on function story_thread(uuid)              from public;
revoke all on function mark_story_seen(uuid)           from public;
revoke all on function story_viewers(uuid)             from public;
revoke all on function delete_story(uuid)              from public;
revoke all on function purge_expired_stories()         from public;
grant execute on function post_story(text, text, uuid[]) to authenticated;
grant execute on function stories_tray()                 to authenticated;
grant execute on function story_thread(uuid)             to authenticated;
grant execute on function mark_story_seen(uuid)          to authenticated;
grant execute on function story_viewers(uuid)            to authenticated;
grant execute on function delete_story(uuid)             to authenticated;

-- ── story-media bucket ───────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('story-media', 'story-media', true, 26214400,
  array['image/jpeg','image/png','image/webp','image/gif','image/avif'])
on conflict (id) do nothing;

create policy "story-media: read" on storage.objects for select
  using (bucket_id = 'story-media');
create policy "story-media: write own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'story-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "story-media: delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'story-media' and owner = auth.uid());
