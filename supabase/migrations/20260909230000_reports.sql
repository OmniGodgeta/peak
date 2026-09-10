-- Peak — Phase 1/5: report content or accounts → a moderation queue.
--
-- Anyone can report a post, profile, community, or message. Reports land in a
-- queue readable by site staff; a report about a community post is also visible
-- to that community's moderators. Urgent categories (CSAM, credible self-harm
-- or violence) are staff-only and flagged — CSAM additionally requires a manual
-- NCMEC report (docs/DEPLOY.md §6).

create type report_reason as enum (
  'spam', 'harassment', 'hate', 'violence', 'self_harm', 'csam',
  'nudity', 'impersonation', 'misinformation', 'other'
);
create type report_status as enum ('open', 'reviewing', 'actioned', 'dismissed');

-- ── site staff ────────────────────────────────────────────────────────
create table staff (
  profile_id uuid primary key references profile (id) on delete cascade,
  added_at   timestamptz not null default now()
);
alter table staff enable row level security;

create or replace function is_staff(p_actor uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff where profile_id = p_actor);
$$;

create policy staff_select on staff for select
  using (profile_id = auth.uid() or is_staff(auth.uid()));
-- staff added via SQL / dashboard only

create or replace function am_i_staff()
returns boolean
language sql stable security definer set search_path = public as $$
  select is_staff(auth.uid());
$$;

-- ── reports ───────────────────────────────────────────────────────────
create table report (
  id           uuid primary key default gen_random_uuid(),
  reporter_id  uuid references profile (id) on delete set null,
  subject_kind text not null
    check (subject_kind in ('post', 'profile', 'community', 'message')),
  subject_id   uuid not null,
  community_id uuid references community (id) on delete set null,
  reason       report_reason not null,
  detail       text check (char_length(detail) <= 2000),
  status       report_status not null default 'open',
  is_urgent    boolean not null default false,
  created_at   timestamptz not null default now(),
  handled_by   uuid references profile (id) on delete set null,
  handled_at   timestamptz,
  resolution   text check (char_length(resolution) <= 1000)
);
create index report_queue_idx
  on report (status, is_urgent desc, created_at);
create index report_by_reporter on report (reporter_id, created_at desc);
create index report_by_community on report (community_id) where community_id is not null;

alter table report enable row level security;
create policy report_select on report for select using (
  reporter_id = auth.uid()
  or is_staff(auth.uid())
  or (
    community_id is not null
    and not is_urgent
    and community_can_moderate(community_id, auth.uid())
  )
);
-- writes via the RPCs below only

create or replace function submit_report(
  p_kind text, p_subject_id uuid, p_reason text, p_detail text default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_reason report_reason := p_reason::report_reason;
  v_community uuid;
  v_urgent boolean := p_reason in ('csam', 'self_harm', 'violence');
  v_id uuid;
begin
  if v_me is null then raise exception 'not authenticated'; end if;
  if p_kind not in ('post', 'profile', 'community', 'message') then
    raise exception 'bad subject kind';
  end if;

  if p_kind = 'post' then
    select community_id into v_community from post where id = p_subject_id;
  elsif p_kind = 'community' then
    v_community := p_subject_id;
  end if;

  -- one open report per reporter per subject
  select id into v_id from report
  where reporter_id = v_me and subject_kind = p_kind
    and subject_id = p_subject_id and status = 'open';
  if v_id is not null then return v_id; end if;

  insert into report
    (reporter_id, subject_kind, subject_id, community_id, reason, detail, is_urgent)
  values
    (v_me, p_kind, p_subject_id, v_community, v_reason,
     nullif(btrim(p_detail), ''), v_urgent)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function my_reports()
returns table (
  id uuid, subject_kind text, subject_id uuid, reason report_reason,
  status report_status, created_at timestamptz, resolution text
)
language sql stable security definer set search_path = public as $$
  select id, subject_kind, subject_id, reason, status, created_at, resolution
  from report where reporter_id = auth.uid()
  order by created_at desc;
$$;

-- the review queue. Site staff see everything; a community moderator sees the
-- non-urgent reports about their community's posts.
create or replace function review_queue(
  p_status text default 'open', p_limit int default 50
)
returns table (
  id uuid, subject_kind text, subject_id uuid, community_id uuid,
  community_slug citext, reason report_reason, detail text,
  status report_status, is_urgent boolean, created_at timestamptz,
  reporter_handle citext, report_count bigint
)
language sql stable security definer set search_path = public as $$
  select
    r.id, r.subject_kind, r.subject_id, r.community_id, c.slug,
    r.reason, r.detail, r.status, r.is_urgent, r.created_at, rp.handle,
    (select count(*) from report r2
     where r2.subject_kind = r.subject_kind and r2.subject_id = r.subject_id)
  from report r
  left join community c on c.id = r.community_id
  left join profile rp on rp.id = r.reporter_id
  where (p_status = 'all' or r.status::text = p_status)
    and (
      is_staff(auth.uid())
      or (r.community_id is not null and not r.is_urgent
          and community_can_moderate(r.community_id, auth.uid()))
    )
  order by r.is_urgent desc, r.created_at
  limit least(p_limit, 200);
$$;

create or replace function resolve_report(
  p_report_id uuid, p_status text, p_resolution text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare v_report report;
begin
  select * into v_report from report where id = p_report_id;
  if v_report.id is null then raise exception 'no such report'; end if;
  if not (
    is_staff(auth.uid())
    or (v_report.community_id is not null and not v_report.is_urgent
        and community_can_moderate(v_report.community_id, auth.uid()))
  ) then
    raise exception 'not allowed to review this report';
  end if;
  if p_status not in ('open', 'reviewing', 'actioned', 'dismissed') then
    raise exception 'bad status';
  end if;

  update report set
    status = p_status::report_status,
    handled_by = auth.uid(),
    handled_at = case when p_status in ('actioned', 'dismissed') then now() end,
    resolution = nullif(btrim(p_resolution), '')
  where id = p_report_id;
end;
$$;

revoke all on function is_staff(uuid)                          from public;
revoke all on function am_i_staff()                            from public;
revoke all on function submit_report(text, uuid, text, text)   from public;
revoke all on function my_reports()                            from public;
revoke all on function review_queue(text, int)                 from public;
revoke all on function resolve_report(uuid, text, text)        from public;
grant execute on function am_i_staff()                          to authenticated;
grant execute on function submit_report(text, uuid, text, text) to authenticated;
grant execute on function my_reports()                          to authenticated;
grant execute on function review_queue(text, int)               to authenticated;
grant execute on function resolve_report(uuid, text, text)      to authenticated;
