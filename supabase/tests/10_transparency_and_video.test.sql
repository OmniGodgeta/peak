-- Transparency report + video extras. Run with: supabase test db
-- One transaction, rolled back at the end.

begin;
select plan(9);

select has_function('public', 'transparency_report', array['integer', 'integer']);

-- 3 spam reports (suppressed), 6 harassment reports (shown)
insert into report (subject_kind, subject_id, reason, created_at, status, handled_at)
select 'post', gen_random_uuid(), 'spam', '2026-08-01', 'dismissed', '2026-08-01 02:00'
from generate_series(1, 3);
insert into report (subject_kind, subject_id, reason, created_at, status, handled_at)
select 'post', gen_random_uuid(), 'harassment', '2026-08-02', 'actioned',
       '2026-08-02'::timestamptz + (g || ' hours')::interval
from generate_series(1, 6) g;

select is((transparency_report(2026, 3) -> 'reports' -> 'by_reason' ->> 'spam')::int,
  -1, 'counts of 1-4 are suppressed to -1');
select is((transparency_report(2026, 3) -> 'reports' -> 'by_reason' ->> 'harassment')::int,
  6, 'counts of 5+ are exact');
select is((transparency_report(2026, 3) -> 'reports' -> 'by_reason' ->> 'hate')::int,
  0, 'zero stays zero');
select is((transparency_report(2026, 4) -> 'reports' ->> 'total')::int,
  0, 'reports outside the quarter are not counted');
select ok((transparency_report(2026, 3) -> 'reports' ->> 'median_hours_to_handle') is not null,
  'median shown once 5+ were handled');
select throws_ok($$ select transparency_report(2026, 5) $$, '22023', null,
  'bad quarter is rejected');

set local role anon;
select lives_ok($$ select transparency_report(2026, 3) $$,
  'signed-out visitors can read the report');
select throws_ok($$ select video_extras(gen_random_uuid()) $$, '42501', null,
  'video_extras is not callable signed out');
reset role;

select finish();
rollback;
