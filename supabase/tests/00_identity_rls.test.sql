-- RLS + bootstrap policy tests. Run with: supabase test db
-- The whole file runs in one transaction that is rolled back at the end.

begin;
create schema if not exists tests;
select plan(28);

select has_table('public', 'profile', 'profile table exists');
select has_table('public', 'profile_private', 'profile_private table exists');

-- ── Fixtures: three auth users ──────────────────────────────────────────────
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'alice@test.peak'),
  ('00000000-0000-0000-0000-00000000000b', 'bob@test.peak'),
  ('00000000-0000-0000-0000-00000000000c', 'kid@test.peak');

-- helper: act as a given user
create or replace function tests.act_as(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid::text, 'role', 'authenticated')::text, true);
end;
$$;

create or replace function tests.act_anon() returns void
language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', json_build_object('role','anon')::text, true);
end;
$$;

grant usage on schema tests to authenticated, anon;
grant execute on all functions in schema tests to authenticated, anon;

-- ── bootstrap_account ───────────────────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ select bootstrap_account('alice', 'Alice', date '1990-05-01') $$,
  'adult can bootstrap an account');

select is(
  (select account_kind::text from profile where id = '00000000-0000-0000-0000-00000000000a'),
  'adult', 'alice is an adult account');

select is(
  (select fq_handle(p) from profile p where id = '00000000-0000-0000-0000-00000000000a'),
  '@alice@peak.social', 'fq_handle renders @name@peak.social');

select is(
  (select count(*)::int from circle where owner_id = '00000000-0000-0000-0000-00000000000a'),
  5, 'alice gets five system circles');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select lives_ok(
  $$ select bootstrap_account('bob', 'Bob', date '2000-01-01') $$,
  'second user can bootstrap');

-- under-13 is rejected
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  $$ select bootstrap_account('kid', 'Kid', (current_date - interval '11 years')::date) $$,
  'you must be at least 13 to use Peak',
  'under-13 sign-up is refused');

-- a 15-year-old becomes a teen account
select lives_ok(
  $$ select bootstrap_account('kid', 'Kid', (current_date - interval '15 years')::date) $$,
  '15-year-old can bootstrap');
select is(
  (select account_kind::text from profile where id = '00000000-0000-0000-0000-00000000000c'),
  'teen', 'under-18 is a teen account');
select is(
  (select is_discoverable from profile where id = '00000000-0000-0000-0000-00000000000c'),
  false, 'teen account is not discoverable by default');

-- ── follow + block ─────────────────────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select lives_ok(
  $$ insert into follow (follower_id, followee_id)
     values ('00000000-0000-0000-0000-00000000000a','00000000-0000-0000-0000-00000000000b') $$,
  'alice can follow bob');

-- bob blocks alice → the follow edge is dropped by trigger
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select lives_ok(
  $$ insert into block (blocker_id, blocked_id)
     values ('00000000-0000-0000-0000-00000000000b','00000000-0000-0000-0000-00000000000a') $$,
  'bob can block alice');
select is(
  (select count(*)::int from follow
   where follower_id='00000000-0000-0000-0000-00000000000a'
     and followee_id='00000000-0000-0000-0000-00000000000b'),
  0, 'blocking removes the follow edge');

-- alice can no longer see bob's profile
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is(
  (select count(*)::int from profile where id='00000000-0000-0000-0000-00000000000b'),
  0, 'a blocked user cannot see the blocker''s profile');

-- ── circle membership is private to the owner ──────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select count(*)::int from circle where owner_id='00000000-0000-0000-0000-00000000000a'),
  0, 'circles are not visible to other users');

-- ── post visibility ───────────────────────────────────────────────────────
-- alice (adult) posts publicly; bob posts to his Friends circle (alice not in it)
select tests.act_as('00000000-0000-0000-0000-00000000000a');
with p as (
  insert into post (author_id, persona_id, body, visibility)
  select '00000000-0000-0000-0000-00000000000a',
         (select id from persona where account_id='00000000-0000-0000-0000-00000000000a'),
         'hello world', 'public'
  returning id
) select id from p \gset alice_pub_

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from post where id = :'alice_pub_id'),
  1, 'a public post is visible to an unrelated user');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
insert into post (author_id, persona_id, body, visibility)
select '00000000-0000-0000-0000-00000000000b',
       (select id from persona where account_id='00000000-0000-0000-0000-00000000000b'),
       'friends only', 'circles'
returning id as bob_fr_post_id \gset
insert into post_audience (post_id, circle_id)
select :'bob_fr_post_id', c.id from circle c
where c.owner_id='00000000-0000-0000-0000-00000000000b' and c.slug='friends';

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from post where id = :'bob_fr_post_id'),
  0, 'a circles post is hidden from a non-member');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select count(*)::int from post where id = :'bob_fr_post_id'),
  1, 'the author can still see their own circles post');

-- ── people: search, follow, feed ───────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000c');  -- kid searches
select is(
  (select handle::text from search_people('alic') limit 1),
  'alice', 'search_people finds a discoverable adult by handle prefix');

select is(
  (select count(*)::int from search_people('a')),
  0, 'search needs at least 2 characters');

select is((select count(*)::int from feed_latest(now() + interval '1h')), 0,
  'feed is empty before following anyone');
insert into follow (follower_id, followee_id)
  values ('00000000-0000-0000-0000-00000000000c','00000000-0000-0000-0000-00000000000a');
select is(
  (select count(*)::int from feed_latest(now() + interval '1h')
   where author_handle = 'alice'),
  1, 'after following, the followee''s public posts appear in the feed');

select is(
  (select is_following from profile_view('alice')),
  true, 'profile_view reflects the follow relationship');

-- ── replies / threads ──────────────────────────────────────────────────────
-- alice has a public post (alice_pub_id). kid replies to it.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
insert into post (author_id, persona_id, body, visibility, reply_to, root_id)
select '00000000-0000-0000-0000-00000000000c',
       (select id from persona where account_id='00000000-0000-0000-0000-00000000000c'),
       'a reply from kid', 'public', :'alice_pub_id', :'alice_pub_id'
returning id as kid_reply_id \gset

select is(
  (select count(*)::int from post_thread(:'alice_pub_id')),
  2, 'post_thread returns the root plus one reply');
select is(
  (select depth from post_thread(:'alice_pub_id') where id = :'kid_reply_id'),
  1, 'the reply is at depth 1');
select is(
  (select reply_count from feed_latest(now() + interval '1h')
   where id = :'alice_pub_id'),
  1::bigint, 'feed_latest reflects the new reply count');

-- bob blocked alice earlier; bob replying then viewing sees the thread minus
-- alice's own posts is out of scope here — just check bob can't open a thread
-- rooted on a post he can't see (alice_pub is public, so he can). Instead:
-- a circles post kid can't see yields an empty thread.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from post_thread(:'bob_fr_post_id')),
  0, 'post_thread is empty when the viewer cannot see the root');

select finish();
rollback;
