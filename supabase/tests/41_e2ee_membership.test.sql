-- E2EE 2.5-4 (20261017000000): commits only through publish_mls_commit, which
-- refuses a commit made at a stale epoch so two devices can't fork a group.
-- Run with: supabase test db

begin;
select plan(9);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000e4a1', 'e4a@test.peak'),
  ('00000000-0000-0000-0000-00000000e4b1', 'e4b@test.peak');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e4b1","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('e4testbob', 'Bob', date '1990-01-01');
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e4a1","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('e4testalice', 'Alice', date '1990-01-01');

create temp table t (conv uuid, dev uuid);
grant all on t to authenticated;
insert into t (dev) select register_device(repeat('ab', 32));
update t set conv = start_dm('00000000-0000-0000-0000-00000000e4b1');
select ok(begin_conversation_e2ee((select conv from t), 'x', 1), 'group claimed at epoch 1');
select ok(enable_conversation_e2ee((select conv from t)), 'conversation encrypted');

select ok(publish_mls_commit((select conv from t), (select dev from t), 1, '\x01'::bytea),
  'a commit made at the current epoch is accepted');
select is((select epoch from mls_group_state where conversation_id = (select conv from t)),
  2::bigint, 'the epoch advances');
select ok(not publish_mls_commit((select conv from t), (select dev from t), 1, '\x02'::bytea),
  'a second commit from the same epoch is refused (no fork)');

select throws_ok(
  $$ insert into mls_message (conversation_id, sender_device_id, epoch, content_type, ciphertext)
     values ((select conv from t), (select dev from t), 2, 'commit', '\x03'::bytea) $$,
  '42501', null, 'commits cannot be inserted directly, bypassing the epoch check');

update mls_group_state set epoch = 99 where conversation_id = (select conv from t);
select is((select epoch from mls_group_state where conversation_id = (select conv from t)),
  2::bigint, 'the group epoch cannot be rewritten directly');

select throws_ok(
  $$ select publish_mls_commit((select conv from t), gen_random_uuid(), 2, '\x04'::bytea) $$,
  'P0001', 'not one of your devices', 'commits must come from one of your own devices');

reset role;
select ok(not has_function_privilege('anon',
  'publish_mls_commit(uuid, uuid, bigint, bytea, jsonb, uuid)', 'execute'),
  'anon cannot call publish_mls_commit');

select finish();
rollback;
