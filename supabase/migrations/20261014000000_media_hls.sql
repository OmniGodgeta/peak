-- Adaptive streaming (HLS) for videos on the self-hosted media server.
-- The server answers an upload with the progressive MP4 straight away and
-- builds a 360p/720p/1080p HLS ladder in the background; hls_path is where
-- that master playlist will be. Players try it first and fall back to the
-- MP4 (while it's still being built, and on web where only Safari plays
-- HLS natively). Null for Supabase-Storage videos.

alter table post_media add column if not exists hls_path text
  check (hls_path is null or hls_path like 'https://%' or hls_path like 'http://%');

create or replace function post_media_json(p_post_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'kind', m.kind,
        'storage_path', m.storage_path,
        'poster_path', m.poster_path,
        'hls_path', m.hls_path,
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
