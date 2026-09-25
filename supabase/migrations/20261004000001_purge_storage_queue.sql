-- storage.protect_delete() rejects DELETE on storage.objects.
-- The purge records bucket paths, hard-deletes the posts, and a local
-- tool removes the objects through the Storage API.

create table media_pending_delete (
  bucket_id text not null default 'post-media',
  object_name text not null,
  queued_at timestamptz not null default now(),
  primary key (bucket_id, object_name)
);

revoke all on media_pending_delete from public, anon, authenticated;

create or replace function purge_expired_deletions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_n integer;
begin
  select coalesce(array_agg(id), '{}')
    into v_ids
  from post
  where deleted_at is not null
    and deleted_at < now() - interval '30 days';

  if cardinality(v_ids) = 0 then
    return 0;
  end if;

  insert into media_pending_delete (bucket_id, object_name)
  select 'post-media', m.storage_path
  from post_media m
  where m.post_id = any (v_ids)
    and m.storage_path not like 'http://%'
    and m.storage_path not like 'https://%'
  on conflict do nothing;

  insert into media_pending_delete (bucket_id, object_name)
  select 'post-media', m.poster_path
  from post_media m
  where m.post_id = any (v_ids)
    and m.poster_path is not null
    and m.poster_path not like 'http://%'
    and m.poster_path not like 'https://%'
  on conflict do nothing;

  delete from post
  where id = any (v_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
