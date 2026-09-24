-- The post-media bucket was created images-only. Video posts (and the
-- Supabase fallback when the media server is off) need mp4.

update storage.buckets
set allowed_mime_types = array[
      'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif',
      'video/mp4', 'video/webm', 'video/quicktime'
    ],
    file_size_limit = 52428800
where id = 'post-media';
