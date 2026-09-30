-- Quarterly transparency report (Phase 5 — the last open moderation item).
--
-- transparency_report(year, quarter) returns aggregate counts only: reports
-- by reason / status / subject, how fast they were handled, label appeals
-- and their outcomes, community moderator actions, labeler labels applied,
-- and proof-of-personhood grants. No ids, handles, or free text.
--
-- Small-number suppression: any count from 1 to 4 is returned as -1 ("fewer
-- than 5"). In a small instance an exact "2 harassment reports in
-- c/rockets" can identify who reported whom; the report should still be
-- publishable. Zero stays zero.
--
-- Readable by anyone, signed in or not: that's the point of it.

create or replace function _tr_count(n bigint)
returns bigint
language sql
immutable
as $$
  select case when n between 1 and 4 then -1 else n end;
$$;

create or replace function transparency_report(p_year int, p_quarter int)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz;
  v_to   timestamptz;
begin
  if p_quarter not between 1 and 4 or p_year not between 2026 and 2100 then
    raise exception 'quarter must be 1-4 and year 2026 or later'
      using errcode = '22023';
  end if;
  v_from := make_timestamptz(p_year, (p_quarter - 1) * 3 + 1, 1, 0, 0, 0, 'UTC');
  v_to   := v_from + interval '3 months';

  return jsonb_build_object(
    'period', jsonb_build_object(
      'year', p_year,
      'quarter', p_quarter,
      'from', v_from,
      'to', v_to,
      'complete', now() >= v_to,
      'generated_at', now()
    ),
    'suppression', 'counts from 1 to 4 are shown as -1 (fewer than 5)',

    'reports', jsonb_build_object(
      'total', (select _tr_count(count(*)) from report
                 where created_at >= v_from and created_at < v_to),
      'urgent', (select _tr_count(count(*)) from report
                  where created_at >= v_from and created_at < v_to and is_urgent),
      'by_reason', (
        select coalesce(jsonb_object_agg(r::text, (
                 select _tr_count(count(*)) from report
                 where reason = r and created_at >= v_from and created_at < v_to
               )), '{}'::jsonb)
        from unnest(enum_range(null::report_reason)) r
      ),
      'by_status', (
        select coalesce(jsonb_object_agg(s::text, (
                 select _tr_count(count(*)) from report
                 where status = s and created_at >= v_from and created_at < v_to
               )), '{}'::jsonb)
        from unnest(enum_range(null::report_status)) s
      ),
      'by_subject', (
        select coalesce(jsonb_object_agg(k, (
                 select _tr_count(count(*)) from report
                 where subject_kind = k and created_at >= v_from and created_at < v_to
               )), '{}'::jsonb)
        from unnest(array['post', 'profile', 'community', 'message']) k
      ),
      -- Median hours from report to decision, for reports handled in the
      -- period. Null when fewer than 5 were handled (same suppression).
      'median_hours_to_handle', (
        select case when count(*) < 5 then null else
          round((percentile_cont(0.5) within group (
            order by extract(epoch from handled_at - created_at) / 3600
          ))::numeric, 1) end
        from report
        where handled_at >= v_from and handled_at < v_to
      )
    ),

    'label_appeals', jsonb_build_object(
      'filed', (select _tr_count(count(*)) from label_appeal
                 where created_at >= v_from and created_at < v_to),
      'upheld', (select _tr_count(count(*)) from label_appeal
                  where status = 'upheld' and resolved_at >= v_from and resolved_at < v_to),
      'rejected', (select _tr_count(count(*)) from label_appeal
                    where status = 'rejected' and resolved_at >= v_from and resolved_at < v_to),
      'still_open', (select _tr_count(count(*)) from label_appeal
                      where status = 'open' and created_at < v_to),
      'median_hours_to_resolve', (
        select case when count(*) < 5 then null else
          round((percentile_cont(0.5) within group (
            order by extract(epoch from resolved_at - created_at) / 3600
          ))::numeric, 1) end
        from label_appeal
        where resolved_at >= v_from and resolved_at < v_to
      )
    ),

    'community_moderation', (
      select coalesce(jsonb_object_agg(a::text, (
               select _tr_count(count(*)) from community_mod_log
               where action = a and created_at >= v_from and created_at < v_to
             )), '{}'::jsonb)
      from unnest(enum_range(null::community_mod_action)) a
    ),

    'labeler_labels_applied', (select _tr_count(count(*)) from content_label
                                where created_at >= v_from and created_at < v_to),

    'personhood_granted', (
      select coalesce(jsonb_object_agg(m::text, (
               select _tr_count(count(*)) from personhood
               where method = m and granted_at >= v_from and granted_at < v_to
             )), '{}'::jsonb)
      from unnest(enum_range(null::personhood_method)) m
    )
  );
end;
$$;

revoke all on function _tr_count(bigint) from public, anon, authenticated;
revoke all on function transparency_report(int, int) from public, anon, authenticated;
grant execute on function transparency_report(int, int) to anon, authenticated;
