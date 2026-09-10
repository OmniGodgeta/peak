-- Peak — link previews.
--
-- A shared cache of OpenGraph/oEmbed metadata for URLs that appear in posts,
-- so the feed can show a rich card (and play a YouTube webcast inline). The
-- `link-preview` Edge Function fetches + parses + writes; the app reads this
-- table directly on a cache hit and calls the function to fill a miss.

create table link_preview (
  url         text primary key,
  final_url   text,
  title       text,
  description text,
  image_url   text,
  site_name   text,
  kind        text not null default 'link',  -- link | video | youtube | photo
  video_id    text,                           -- youtube id, when kind = youtube
  ok          boolean not null default true,  -- false = fetch failed / blocked
  fetched_at  timestamptz not null default now()
);

alter table link_preview enable row level security;

-- Metadata about public web pages — readable by any signed-in user. Writes are
-- service-role only (the Edge Function).
create policy link_preview_read on link_preview
  for select to authenticated using (true);

comment on table link_preview is
  'OG/oEmbed metadata cache for URLs in posts. Written by the link-preview Edge Function.';
