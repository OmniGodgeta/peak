-- Guards against the class of bug fixed in 20261014000001: tables created
-- without RLS (Supabase then grants anon full access) and SECURITY DEFINER
-- functions that act on an arbitrary user id. Run with: supabase test db

begin;
select plan(8);

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  0, 'every public table has row-level security enabled');

set local role anon;
select throws_ok($$ select * from account_exports $$, '42501', null, 'anon cannot read account_exports');
select throws_ok($$ select * from system_config $$, '42501', null, 'anon cannot read system_config');
select throws_ok($$ update system_config set value = 'true' $$, '42501', null, 'anon cannot flip federation on');
select throws_ok($$ select * from federation_job $$, '42501', null, 'anon cannot read the federation delivery queue');
select throws_ok($$ select * from fanout_feed_index $$, '42501', null, 'anon cannot read feed indexes');
select throws_ok($$ select export_account(gen_random_uuid()) $$, '42501', null, 'anon cannot export accounts');
reset role;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000e1', 'exp1@test.peak');
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000e1","role":"authenticated"}', true);
set local role authenticated;
select throws_ok(
  $$ select export_account('00000000-0000-0000-0000-0000000000e2') $$,
  '42501', null, 'a user cannot export someone else''s account');
reset role;

select finish();
rollback;
