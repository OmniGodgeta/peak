-- Federation rules. Run with: supabase test db
begin;
select plan(7);

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000f1', 'fed-adult@test.peak'),
  ('00000000-0000-0000-0000-0000000000f2', 'fed-teen@test.peak');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('fedadult', 'Fed Adult', date '1990-01-01');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f2","role":"authenticated"}', true);
set local role authenticated;
select bootstrap_account('fedteen', 'Fed Teen', (now() - interval '15 years')::date);
select throws_ok($$ select set_my_federation(true, null) $$, '42501', null,
  'teen accounts cannot turn federation on');
reset role;

update system_config set value = 'true' where key = 'federation_enabled';
update profile set federated = true where handle = 'fedadult';
insert into remote_actor (id, uri, domain, inbox)
values ('00000000-0000-0000-0000-0000000000a1', 'https://remote.test/users/z', 'remote.test', 'https://remote.test/inbox');
insert into remote_follower (local_profile_id, remote_actor_id)
values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1');

insert into post (id, author_id, persona_id, body, visibility)
select '00000000-0000-0000-0000-0000000000b1', id,
       (select id from persona where account_id = profile.id and is_default), 'hi all', 'public'
from profile where handle = 'fedadult';
insert into post (id, author_id, persona_id, body, visibility)
select '00000000-0000-0000-0000-0000000000b2', id,
       (select id from persona where account_id = profile.id and is_default), 'circle only', 'circles'
from profile where handle = 'fedadult';

select is((select count(*)::int from federation_job where kind = 'create' and object_id = '00000000-0000-0000-0000-0000000000b1'),
  1, 'a public post by a federated account is queued');
select is((select count(*)::int from federation_job where object_id = '00000000-0000-0000-0000-0000000000b2'),
  0, 'a circles post is never queued');

update post set deleted_at = now() where id = '00000000-0000-0000-0000-0000000000b1';
select is((select count(*)::int from federation_job where kind = 'delete' and object_id = '00000000-0000-0000-0000-0000000000b1'),
  1, 'deleting a federated post queues a Delete');

insert into remote_post (uri, remote_actor_id, body, in_reply_to_post, published_at)
values ('https://remote.test/notes/1', '00000000-0000-0000-0000-0000000000a1', 'reply',
        '00000000-0000-0000-0000-0000000000b2', now());
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f2","role":"authenticated"}', true);
set local role authenticated;
select is((select count(*)::int from remote_replies('00000000-0000-0000-0000-0000000000b2')),
  0, 'remote replies follow the local post''s visibility');
select throws_ok($$ select * from actor_key $$, '42501', null, 'private keys are unreadable');
reset role;

set local role anon;
select lives_ok($$ select * from federation_blocklist() $$, 'the blocklist is public');
reset role;

select finish();
rollback;
