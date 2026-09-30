-- Audio-only posts (media_kind 'audio' has existed since the first posts
-- migration). Phones record AAC in .m4a (audio/mp4); browsers record Opus in
-- WebM. mp3/ogg/wav are accepted for uploads from elsewhere.

update storage.buckets
set allowed_mime_types = array[
      'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/avif',
      'video/mp4', 'video/webm', 'video/quicktime',
      'audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/ogg', 'audio/webm',
      'audio/wav', 'audio/x-wav'
    ]
where id = 'post-media';
