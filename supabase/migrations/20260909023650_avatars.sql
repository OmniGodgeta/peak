-- Peak — profile editing: an avatars bucket. The `profile` row itself is
-- already editable by its owner (profile_update RLS from migration 1); the
-- client writes display_name / bio / pronouns / links / avatar_path directly.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'avatars', 'avatars', true,
  5242880,  -- 5 MB
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do nothing;

create policy "avatars: public read"
  on storage.objects for select
  using (bucket_id = 'avatars');

create policy "avatars: write own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars: update own"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and owner = auth.uid());

create policy "avatars: delete own"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and owner = auth.uid());

-- Tighten the links shape: an array of {label, url} objects, max 5.
alter table profile drop constraint if exists profile_links_shape;
alter table profile add constraint profile_links_shape check (
  jsonb_typeof(links) = 'array' and jsonb_array_length(links) <= 5
);
