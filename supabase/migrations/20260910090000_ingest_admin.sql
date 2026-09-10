-- Peak — staff tools for the mirror/news feeds.
--
-- A light review surface for content posted by `ingest-content`: see recent
-- items, hide a bad one, and turn a source on/off (the Edge Function checks
-- content_ingest_run.enabled before running a source).

alter table content_ingest_run add column enabled boolean not null default true;

-- staff-only: soft-delete any post (used to hide a bad auto-posted item, but
-- works for anything). Distinct from delete_post, which is author-only.
create or replace function admin_remove_post(p_post_id uuid, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff(auth.uid()) then raise exception 'staff only'; end if;
  update post
     set deleted_at = coalesce(deleted_at, now())
   where id = p_post_id;
  if not found then raise exception 'no such post'; end if;
end;
$$;

-- per-source state for the admin screen
create or replace function ingest_admin_sources()
returns table (
  source text, enabled boolean, last_run_at timestamptz, last_ok_at timestamptz,
  added_last int, note text, seen_total bigint, live_total bigint
)
language sql stable security definer set search_path = public as $$
  select
    r.source, r.enabled, r.last_run_at, r.last_ok_at, r.added_last, r.note,
    (select count(*) from content_ingest_seen s where s.source = r.source),
    (select count(*) from content_ingest_seen s
       join post p on p.id = s.post_id
      where s.source = r.source and p.deleted_at is null)
  from content_ingest_run r
  where is_staff(auth.uid())
  order by r.source;
$$;

create or replace function ingest_set_source_enabled(p_source text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff(auth.uid()) then raise exception 'staff only'; end if;
  insert into content_ingest_run (source, enabled)
  values (p_source, p_enabled)
  on conflict (source) do update set enabled = excluded.enabled;
end;
$$;

create or replace function ingest_recent(p_limit int default 40)
returns table (
  source text, external_id text, title text, url text, seen_at timestamptz,
  post_id uuid, post_body text, post_deleted boolean, community_slug citext
)
language sql stable security definer set search_path = public as $$
  select
    s.source, s.external_id, s.title, s.url, s.seen_at,
    s.post_id, p.body, (p.deleted_at is not null), c.slug
  from content_ingest_seen s
  left join post p on p.id = s.post_id
  left join community c on c.id = p.community_id
  where is_staff(auth.uid())
  order by s.seen_at desc
  limit least(p_limit, 200);
$$;

revoke all on function admin_remove_post(uuid, text) from public, anon;
revoke all on function ingest_admin_sources() from public, anon;
revoke all on function ingest_set_source_enabled(text, boolean) from public, anon;
revoke all on function ingest_recent(int) from public, anon;
grant execute on function admin_remove_post(uuid, text) to authenticated;
grant execute on function ingest_admin_sources() to authenticated;
grant execute on function ingest_set_source_enabled(text, boolean) to authenticated;
grant execute on function ingest_recent(int) to authenticated;
