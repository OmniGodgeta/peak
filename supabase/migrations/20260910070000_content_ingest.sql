-- Peak — content ingestion bookkeeping.
--
-- The `ingest-content` Edge Function mirrors public feeds into Peak as posts by
-- dedicated accounts (@webb / @hubble / @roman from NASA's public image library,
-- @launches from the free Launch Library). These two tables are its memory: what
-- has already been posted, and when each source last ran.
--
-- Internal only — the function runs with the service role, which bypasses RLS.
-- No grants to anon/authenticated; RLS on with deny-all so nothing leaks if a
-- grant is ever added by accident.

create table content_ingest_seen (
  source      text not null,               -- 'webb' | 'hubble' | 'roman' | 'launches'
  external_id text not null,               -- NASA nasa_id, or Launch Library UUID
  kind        text not null default 'post',
  post_id     uuid references post (id) on delete set null,
  title       text,
  url         text,                        -- canonical source URL
  seen_at     timestamptz not null default now(),
  primary key (source, external_id)
);
create index content_ingest_seen_by_time on content_ingest_seen (seen_at desc);

create table content_ingest_run (
  source       text primary key,
  last_run_at  timestamptz,
  last_ok_at   timestamptz,
  added_last   int not null default 0,
  note         text
);

alter table content_ingest_seen enable row level security;
alter table content_ingest_run  enable row level security;
create policy content_ingest_seen_none on content_ingest_seen for all using (false) with check (false);
create policy content_ingest_run_none  on content_ingest_run  for all using (false) with check (false);

comment on table content_ingest_seen is
  'Dedup log for the ingest-content Edge Function. Internal; service-role only.';
comment on table content_ingest_run is
  'Per-source last-run marker for the ingest-content Edge Function. Internal.';
