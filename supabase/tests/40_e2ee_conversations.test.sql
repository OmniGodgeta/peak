-- E2EE 2.5-3 (20261016000000): setting up an encrypted conversation, and the
-- guards that keep plaintext out of it. Run with: supabase test db

begin;
select plan(13);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000e2a1', 'e2a@test.peak'),
  ('00000000-0000-0000-0000-00000000e2b1', 'e2b@test.peak');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e2b1","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('e2etestbob', 'Bob', date '1990-01-01');
reset role;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e2a1","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('e2etestalice', 'Alice', date '1990-01-01');
reset role;

create temp table t (conv uuid, plain uuid, msg uuid);
grant all on t to authenticated;

-- Alice opens a DM with Bob, and a second (plaintext) one we won't encrypt.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e2a1","role":"authenticated"}', true);
set local role authenticated;
insert into t (conv) select start_dm('00000000-0000-0000-0000-00000000e2b1');
select ok(begin_conversation_e2ee((select conv from t), 'MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519', 1),
  'the first device claims the conversation''s MLS group');
select ok(not begin_conversation_e2ee((select conv from t), 'x', 1),
  'a second claim on the same conversation is refused');
select ok(enable_conversation_e2ee((select conv from t)), 'the claimer can switch it to encrypted');

select throws_ok(
  $$ insert into message (conversation_id, sender_id, body)
     values ((select conv from t), auth.uid(), 'hello in the clear') $$,
  'P0001', 'this conversation is end-to-end encrypted',
  'plaintext cannot be sent into an encrypted conversation');

insert into message (conversation_id, sender_id, body, ciphertext, mls_epoch)
values ((select conv from t), auth.uid(), '', '\x00010203'::bytea, 1);
update t set msg = (select id from message where conversation_id = t.conv);
select isnt((select msg from t), null, 'ciphertext can be sent');

select throws_ok(
  $$ insert into message (conversation_id, sender_id, body, ciphertext)
     values ((select conv from t), auth.uid(), 'leak', '\x00'::bytea) $$,
  '23514', null, 'a message cannot carry both ciphertext and a body');

select is(
  (select encode(ciphertext, 'hex') from messages_page((select conv from t), now() + interval '1 minute') limit 1),
  '00010203', 'messages_page returns the ciphertext');
select is(
  (select e2ee from conversations_list(true) where id = (select conv from t)),
  true, 'conversations_list reports the conversation as encrypted');

select edit_message((select msg from t), 'edited in the clear');
select is((select body from message where id = (select msg from t)), '',
  'an encrypted message cannot be edited into plaintext');

select throws_ok(
  $$ insert into message_media (message_id, kind, storage_path)
     values ((select msg from t), 'image', 'x/y.jpg') $$,
  'P0001', 'attachments are not supported in encrypted conversations yet',
  'attachments are refused in encrypted conversations');

select delete_message((select msg from t));
select is((select ciphertext from message where id = (select msg from t)), null,
  'deleting an encrypted message drops its ciphertext');

-- Bob cannot take over Alice's group.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e2b1","role":"authenticated"}', true);
select throws_ok($$ select enable_conversation_e2ee((select conv from t)) $$,
  'P0001', 'no MLS group claimed by you for this conversation',
  'only the device that claimed the group can enable encryption');

-- A plaintext conversation refuses ciphertext.
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000e2a1","role":"authenticated"}', true);
insert into t (plain) select create_group('plain group', array['00000000-0000-0000-0000-00000000e2b1'::uuid]);
select throws_ok(
  $$ insert into message (conversation_id, sender_id, body, ciphertext)
     values ((select plain from t where plain is not null), auth.uid(), '', '\x00'::bytea) $$,
  'P0001', 'this conversation is not end-to-end encrypted',
  'ciphertext cannot be sent into a plaintext conversation');

reset role;
select finish();
rollback;
