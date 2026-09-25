-- Remove stored files only when a post is hard-deleted, after the 30-day
-- restore window. Soft-delete (delete_post) still only sets deleted_at.
-- Paths that are full URLs belong to the media server and are not in the bucket.

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

  delete from storage.objects o
  using post_media m
  where m.post_id = any (v_ids)
    and o.bucket_id = 'post-media'
    and o.name = m.storage_path
    and m.storage_path not like 'http://%'
    and m.storage_path not like 'https://%';

  delete from storage.objects o
  using post_media m
  where m.post_id = any (v_ids)
    and o.bucket_id = 'post-media'
    and m.poster_path is not null
    and o.name = m.poster_path
    and m.poster_path not like 'http://%'
    and m.poster_path not like 'https://%';

  delete from post
  where id = any (v_ids);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
