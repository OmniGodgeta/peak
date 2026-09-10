-- RLS + bootstrap policy tests. Run with: supabase test db
-- The whole file runs in one transaction that is rolled back at the end.

begin;
create schema if not exists tests;
select plan(177);

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

-- ── messaging ──────────────────────────────────────────────────────────────
-- kid follows alice (from earlier). alice starts a DM with kid.
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select start_dm('00000000-0000-0000-0000-00000000000c') as dm_id \gset
select ok(:'dm_id' is not null, 'start_dm returns a conversation id');
select is(
  (select start_dm('00000000-0000-0000-0000-00000000000c')),
  :'dm_id'::uuid, 'start_dm is idempotent for the same pair');

-- kid follows alice, so kid's side is active (not a request)
select is(
  (select my_state::text from conversations_list(true)
   where id = :'dm_id'),
  'active', 'recipient who follows the sender gets an active conversation');

insert into message (conversation_id, sender_id, body)
  values (:'dm_id', '00000000-0000-0000-0000-00000000000a', 'hi kid');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from messages_page(:'dm_id', now() + interval '1h')),
  1, 'the recipient can read the message');
-- backdate our read marker so the message (created "now") counts as unread;
-- in real use last_read_at predates later messages naturally.
update conversation_member set last_read_at = now() - interval '1 minute'
  where conversation_id = :'dm_id' and member_id = '00000000-0000-0000-0000-00000000000c';
select is(
  (select unread_count from conversations_list(true) where id = :'dm_id'),
  1::bigint, 'unread count reflects an unseen message');
select mark_conversation_read(:'dm_id');
select is(
  (select unread_count from conversations_list(true) where id = :'dm_id'),
  0::bigint, 'unread count is 0 after mark_conversation_read');

-- bob is not a member → sees nothing and cannot send
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select count(*)::int from message where conversation_id = :'dm_id'),
  0, 'a non-member cannot read the conversation''s messages');
select throws_ok(
  format(
    $f$ insert into message (conversation_id, sender_id, body)
        values (%L, '00000000-0000-0000-0000-00000000000b', 'butting in') $f$,
    :'dm_id'
  ),
  null, 'a non-member cannot send into the conversation');

-- ── groups + edit/delete + read receipts ───────────────────────────────────
-- alice + bob are blocked (from earlier), so create_group must skip bob and
-- keep only alice + kid.
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select create_group('Test group', array['00000000-0000-0000-0000-00000000000b',
                                         '00000000-0000-0000-0000-00000000000c']::uuid[]) as grp \gset
select is(
  (select count(*)::int from conversation_members(:'grp')),
  2, 'create_group adds the creator + unblocked members (bob is skipped)');
select is(
  (select is_group from conversation where id = :'grp'),
  true, 'a created group is flagged is_group');

insert into message (conversation_id, sender_id, body)
  values (:'grp', '00000000-0000-0000-0000-00000000000a', 'draft')
  returning id as gmsg \gset
select edit_message(:'gmsg', 'final');
select is((select body from message where id = :'gmsg'), 'final',
  'edit_message updates the body');
select delete_message(:'gmsg');
select is((select deleted_at is not null from message where id = :'gmsg'), true,
  'delete_message tombstones the row');

-- read receipts: hidden until both members opt in
select is((select count(*)::int from conversation_read_state(:'grp')), 0,
  'read receipts are hidden by default');

-- a member can leave (RLS allows deleting your own membership)
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select leave_conversation(:'grp');
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is(
  (select count(*)::int from conversation_members(:'grp')),
  1, 'leave_conversation removes the caller from the group');

-- ── E2EE foundation: devices + key packages ────────────────────────────────
-- kid registers two devices (kid follows alice, no block between them)
select tests.act_as('00000000-0000-0000-0000-00000000000c');
insert into device (account_id, public_sig_key, label)
  values ('00000000-0000-0000-0000-00000000000c', '\x01', 'phone')
  returning id as kid_dev \gset
insert into key_package (device_id, data) values
  (:'kid_dev', '\xaa'), (:'kid_dev', '\xbb');

select tests.act_as('00000000-0000-0000-0000-00000000000a');  -- alice claims
select is(
  (select count(*)::int from claim_key_packages(
     array['00000000-0000-0000-0000-00000000000c']::uuid[])),
  1, 'claim_key_packages returns one package per device');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from key_package where consumed_at is not null),
  1, 'claiming marks exactly one package consumed');

-- another account can't read a device's raw key_package rows
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select count(*)::int from key_package),
  0, 'key_package rows are private to the owning device');

-- ── E2EE 2.5-2: device registration API ───────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000b');  -- bob
select register_device(
  '1111111111111111111111111111111111111111111111111111111111111111', 'bob laptop'
) as bob_dev \gset
select ok(:'bob_dev' is not null, 'register_device returns a device id');
select is(
  (select register_device(
     '1111111111111111111111111111111111111111111111111111111111111111', 'bob laptop')),
  :'bob_dev'::uuid,
  'register_device is idempotent on (account, public_sig_key)');
select is((select count(*)::int from my_devices()), 1,
  'my_devices lists the caller''s one device');
select is((select unclaimed_packages from my_devices() where id = :'bob_dev'), 0,
  'a fresh device has an empty key-package pool');
select rename_device(:'bob_dev', 'bob workstation');
select is((select label from my_devices() where id = :'bob_dev'), 'bob workstation',
  'rename_device updates the label');

-- alice cannot revoke bob's device
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select revoke_device(:'bob_dev');
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is((select revoked_at from my_devices() where id = :'bob_dev'), null,
  'revoke_device only affects the caller''s own devices');

-- key-package pool plumbing
select is((select publish_key_packages(:'bob_dev', array['cc','dd']::text[])), 2,
  'publish_key_packages appends the caller''s packages');
select is((select key_package_pool(:'bob_dev')), 2,
  'key_package_pool counts unconsumed packages');
select throws_ok(
  $$select publish_key_packages('00000000-0000-0000-0000-000000000000'::uuid, array['ee']::text[])$$,
  'not your device',
  'publish_key_packages rejects a device you do not own');

-- owner revokes: device is flagged and its unclaimed packages are burned
select revoke_device(:'bob_dev');
select isnt((select revoked_at from my_devices() where id = :'bob_dev'), null,
  'revoke_device sets revoked_at for the owner');
select is((select key_package_pool(:'bob_dev')), 0,
  'revoking a device burns its unclaimed key packages');

-- ── Phase 3: data controls (real delete + bin, export) ────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
insert into post (author_id, persona_id, body, visibility)
values ('00000000-0000-0000-0000-00000000000a',
        (select id from persona where account_id = '00000000-0000-0000-0000-00000000000a'),
        'delete me', 'public')
returning id as del_test_id \gset

-- kid is not the author
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format($$select delete_post(%L)$$, :'del_test_id'),
  'post not found',
  'delete_post refuses a post you do not own');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select delete_post(:'del_test_id');
select is((select count(*)::int from my_deleted_posts() where id = :'del_test_id'), 1,
  'delete_post moves the post to the recently-deleted bin');
select is(
  (select purges_at::date from my_deleted_posts() where id = :'del_test_id'),
  (now() + interval '30 days')::date,
  'the bin shows a 30-day purge date');
select is(
  (select count(*)::int from feed_latest(now() + interval '1 hour', 100)
   where id = :'del_test_id'),
  0, 'a deleted post is gone from the feed');

select restore_post(:'del_test_id');
select is((select count(*)::int from my_deleted_posts() where id = :'del_test_id'), 0,
  'restore_post empties it from the bin');
select is(
  (select count(*)::int from feed_latest(now() + interval '1 hour', 100)
   where id = :'del_test_id'),
  1, 'a restored post is back in the feed');

select is(export_my_data() ->> 'peak_export_version', '1',
  'export_my_data stamps the format version');
select is(jsonb_typeof(export_my_data() -> 'posts'), 'array',
  'export_my_data returns a posts array');

-- purge sweeps rows past the 30-day window (backdate as the table owner, since
-- RLS hides soft-deleted rows even from a plain UPDATE by their author)
select delete_post(:'del_test_id');
set local role postgres;
update post set deleted_at = now() - interval '40 days' where id = :'del_test_id';
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select ok((select purge_expired_deletions()) >= 1,
  'purge_expired_deletions hard-deletes posts past the 30-day window');
select is((select count(*)::int from my_deleted_posts() where id = :'del_test_id'), 0,
  'the purged post is gone for good');

-- ── Phase 3: long-form articles ──────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ insert into post (author_id, persona_id, body, visibility, long_form)
     select '00000000-0000-0000-0000-00000000000a',
            (select id from persona where account_id = '00000000-0000-0000-0000-00000000000a'),
            'no title', 'public', true $$,
  'new row for relation "post" violates check constraint "post_article_needs_title"',
  'a long_form post with no title is rejected');

insert into post (author_id, persona_id, title, body, visibility, long_form)
select '00000000-0000-0000-0000-00000000000a',
       (select id from persona where account_id = '00000000-0000-0000-0000-00000000000a'),
       'My First Article', 'A paragraph.', 'public', true
returning id as art_id \gset
select is(
  (select long_form from feed_latest(now() + interval '1 hour', 100) where id = :'art_id'),
  true, 'feed_latest carries the long_form flag');
select is(
  (select title from feed_latest(now() + interval '1 hour', 100) where id = :'art_id'),
  'My First Article', 'feed_latest carries the article title');

-- ── Phase 3: profile pins ────────────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select pin_post(:'art_id');
select is(
  (select is_pinned from posts_by('00000000-0000-0000-0000-00000000000a', now() + interval '1 hour', 100)
   where id = :'art_id'),
  true, 'pin_post marks the post pinned in posts_by');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format($$select pin_post(%L)$$, :'art_id'),
  'you can only pin your own top-level posts',
  'pin_post refuses a post you do not own');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select unpin_post(:'art_id');
select is(
  (select is_pinned from posts_by('00000000-0000-0000-0000-00000000000a', now() + interval '1 hour', 100)
   where id = :'art_id'),
  false, 'unpin_post clears the pin');

-- ── Phase 3: stories ─────────────────────────────────────────────────────
-- alice adds kid to her Friends circle, then posts a story to it. kid follows
-- alice (from earlier), so kid is a valid audience member.
select tests.act_as('00000000-0000-0000-0000-00000000000a');
insert into circle_member (circle_id, member_id)
select c.id, '00000000-0000-0000-0000-00000000000c'
from circle c
where c.owner_id = '00000000-0000-0000-0000-00000000000a' and c.slug = 'friends';

select post_story(
  '00000000-0000-0000-0000-00000000000a/pic.jpg',
  'first story',
  array[(select id from circle
         where owner_id = '00000000-0000-0000-0000-00000000000a' and slug = 'friends')]::uuid[]
) as sid \gset

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from stories_tray()
   where author_id = '00000000-0000-0000-0000-00000000000a'),
  1, 'an addressed circle-member sees the story in their tray');
select is(
  (select count(*)::int from story_thread('00000000-0000-0000-0000-00000000000a')),
  1, 'story_thread returns the addressed story');
select is(
  (select seen from story_thread('00000000-0000-0000-0000-00000000000a') limit 1),
  false, 'a fresh story is unseen');
select mark_story_seen(:'sid');
select is(
  (select seen from story_thread('00000000-0000-0000-0000-00000000000a') limit 1),
  true, 'mark_story_seen flips the seen flag');

-- bob: not in the circle and blocked with alice → nothing
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is(
  (select count(*)::int from story_thread('00000000-0000-0000-0000-00000000000a')),
  0, 'a non-member does not see the story');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from story_viewers(:'sid')), 1,
  'the author sees who viewed');
select is(
  (select viewer_count from story_thread('00000000-0000-0000-0000-00000000000a') limit 1),
  1, 'story_thread reports the viewer count to the author');

set local role postgres;
update story set expires_at = now() - interval '1 hour' where id = :'sid';
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is(
  (select count(*)::int from story_thread('00000000-0000-0000-0000-00000000000a')),
  0, 'an expired story drops out of story_thread');
select ok((select purge_expired_stories()) >= 1,
  'purge_expired_stories removes expired stories');

-- ── Phase 4: communities ─────────────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select create_community(
  'rust-lang', 'Rustaceans', 'All things Rust',
  array['programming', 'rust'], 'open', false
) as cid \gset
select is((select my_role::text from community_view('rust-lang')), 'admin',
  'the creator is an admin member');
select is((select member_count from community_view('rust-lang')), 1,
  'a new community has one member');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from communities_browse('rust')), 1,
  'communities_browse finds an open community');
select is(join_community(:'cid')::text, 'active',
  'joining an open community is immediate');
select is(
  (select count(*)::int from my_communities() where slug = 'rust-lang'),
  1, 'the community shows in my_communities after joining');

insert into post (author_id, persona_id, body, visibility, community_id)
select '00000000-0000-0000-0000-00000000000c',
       (select id from persona where account_id = '00000000-0000-0000-0000-00000000000c'),
       'hello rust', 'public', :'cid'
returning id as cpost \gset

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is(
  (select count(*)::int from community_feed(:'cid', now() + interval '1 hour', 50)),
  1, 'a community post shows in community_feed for members');
select is(
  (select count(*)::int from feed_latest(now() + interval '1 hour', 100)
   where id = :'cpost'),
  0, 'community posts stay out of the home feed');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select create_community('secret-club', 'Secret Club', '', '{}', 'request', false)
  as sid \gset
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(join_community(:'sid')::text, 'request',
  'joining a request-policy community creates a pending request');

select leave_community(:'cid');
select is(
  (select count(*)::int from my_communities() where slug = 'rust-lang'),
  0, 'leave_community removes membership');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select throws_ok(
  format($$select leave_community(%L)$$, :'cid'),
  'promote another admin before you leave',
  'the last admin cannot leave');

-- ── Phase 4-1: moderation ────────────────────────────────────────────────
-- kid requested secret-club earlier; bob (its admin) approves.
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from community_pending_requests(:'sid')), 1,
  'a moderator sees the pending join request');
select approve_request(:'sid', '00000000-0000-0000-0000-00000000000c');
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select count(*)::int from my_communities() where slug = 'secret-club'),
  1, 'approve_request makes the requester an active member');

-- roles + removal on the open community
select is(join_community(:'cid')::text, 'active', 'kid rejoins the open community');
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select set_member_role(:'cid', '00000000-0000-0000-0000-00000000000c', 'moderator');
select is(
  (select role::text from community_roster(:'cid')
   where member_id = '00000000-0000-0000-0000-00000000000c'),
  'moderator', 'set_member_role promotes a member');
select throws_ok(
  format($$select set_member_role(%L, %L, 'member')$$,
         :'cid', '00000000-0000-0000-0000-00000000000a'),
  'promote another admin first', 'the last admin cannot be demoted');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format($$select remove_member(%L, %L)$$,
         :'cid', '00000000-0000-0000-0000-00000000000a'),
  'you can only remove members', 'a moderator cannot remove an admin');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select remove_member(:'cid', '00000000-0000-0000-0000-00000000000c', true);
select is((select count(*)::int from community_banned(:'cid')), 1,
  'remove_member with ban lists the user as banned');
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format($$select join_community(%L)$$, :'cid'),
  'you can''t join this community', 'a banned user cannot rejoin');

-- ── Phase 4-2: mod log + labels ─────────────────────────────────────────
-- alice has run set_role + ban on rust-lang by now.
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select ok((select count(*)::int from community_mod_log(:'cid')) >= 2,
  'moderator actions are recorded in the mod log');
select is(
  (select count(*)::int from community_mod_log(:'cid') where action = 'ban_member'),
  1, 'the ban is in the mod log');
select is(
  (select count(*)::int from community_mod_log(:'cid') where action = 'set_role'),
  1, 'the role change is in the mod log');

-- kid is banned → no longer a member → can't read the log
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from community_mod_log(:'cid')), 0,
  'a non-member sees no mod log');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
insert into post (author_id, persona_id, body, visibility, community_id)
select '00000000-0000-0000-0000-00000000000a',
       (select id from persona where account_id = '00000000-0000-0000-0000-00000000000a'),
       'a community post', 'public', :'cid'
returning id as cmp \gset

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  format($$select label_post(%L, 'off-topic')$$, :'cmp'),
  'not a moderator', 'a non-moderator cannot label a post');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select label_post(:'cmp', 'off-topic', 'Wrong place for this.');
select is(
  (select label from community_feed(:'cid', now() + interval '1 hour', 50)
   where id = :'cmp'),
  'off-topic', 'label_post shows a label in community_feed');
select is(
  (select count(*)::int from community_mod_log(:'cid') where action = 'label_post'),
  1, 'labeling a post is logged');
select unlabel_post(:'cmp');
select is(
  (select label from community_feed(:'cid', now() + interval '1 hour', 50)
   where id = :'cmp'),
  null, 'unlabel_post clears the label');

select moderate_remove_post(:'cmp', 'spam');
select is(
  (select count(*)::int from community_feed(:'cid', now() + interval '1 hour', 50)
   where id = :'cmp'),
  0, 'moderate_remove_post takes the post out of the feed');
select is(
  (select count(*)::int from community_mod_log(:'cid') where action = 'remove_post'),
  1, 'a moderator removal is logged');

-- ── Phase 4-3a: rules + flair ───────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select set_community_rules(
  :'cid',
  '[{"title":"Be kind","body":"No harassment."},{"title":"Stay on topic"}]'::jsonb
);
select is((select count(*)::int from community_rules(:'cid')), 2,
  'set_community_rules stores the rule set');
select is((select title from community_rules(:'cid') where ord = 0), 'Be kind',
  'rules keep their order');

-- kid is an active member of secret-club (approved earlier); set flair
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select set_my_flair(:'sid', 'newbie');
select is(
  (select flair from community_roster(:'sid')
   where member_id = '00000000-0000-0000-0000-00000000000c'),
  'newbie', 'set_my_flair updates the member''s flair');

-- non-member can't set flair; non-admin can't set rules
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select throws_ok(
  format($$select set_my_flair(%L, 'x')$$, :'sid'),
  'not an active member', 'a non-member cannot set flair');
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format($$select set_community_rules(%L, '[]'::jsonb)$$, :'sid'),
  'only an admin can set the rules', 'a non-admin cannot set the rules');

-- ── Phase 4-3b: modmail ────────────────────────────────────────────────
-- kid is an active member of secret-club; bob is its admin.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select start_modmail(:'sid', 'Question about rule 2', 'What counts as off-topic?')
  as mm \gset
select is((select count(*)::int from my_modmail_threads() where id = :'mm'), 1,
  'start_modmail opens a thread the member can see');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from community_modmail_threads(:'sid', 'open')), 1,
  'a moderator sees the open modmail thread');
select is(
  (select member_state::text from community_modmail_threads(:'sid', 'open')
   where id = :'mm'),
  'active', 'the queue shows the member''s community state');
select modmail_reply(:'mm', 'Off-topic means not about the club.');
select is((select count(*)::int from modmail_messages(:'mm')), 2,
  'modmail_reply appends a message');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select last_from_mod from my_modmail_threads() where id = :'mm'), true,
  'the member sees the moderator reply');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is((select count(*)::int from modmail_messages(:'mm')), 0,
  'someone who is neither the member nor a mod cannot read the thread');

-- a banned member can still open modmail (a ban appeal). kid is banned from :'cid'.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select start_modmail(:'cid', 'Appeal', 'I would like to appeal my ban.')
  as appeal \gset
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select is(
  (select member_state::text from community_modmail_threads(:'cid', 'open')
   where id = :'appeal'),
  'banned', 'a banned member can still open modmail to appeal');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  format($$select start_modmail(%L, 'x', 'y')$$, :'sid'),
  'moderators reply to modmail, they do not open it',
  'a moderator cannot open modmail');
select set_modmail_state(:'mm', false);
select throws_ok(
  format($$select modmail_reply(%L, 'anything')$$, :'mm'),
  'this thread is closed', 'a closed thread rejects replies');

-- ── Phase 4-4a: channels ───────────────────────────────────────────────
-- :'sid' is secret-club (bob admin, kid active member).
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from community_channels(:'sid')), 1,
  'a community starts with one channel (general)');
select create_channel(:'sid', 'staff', 'Staff room', 'mods only', true)
  as staff \gset
select is((select count(*)::int from community_channels(:'sid')), 2,
  'create_channel adds a channel');
select is(
  (select post_policy::text from community_channels(:'sid') where slug = 'staff'),
  'moderators', 'a mods-only channel records its policy');
select (select id from community_channels(:'sid') where slug = 'general')
  as gen \gset

-- an admin can post in a mods-only channel; it shows in the channel-filtered feed
insert into post (author_id, persona_id, body, visibility, community_id, channel_id)
select '00000000-0000-0000-0000-00000000000b',
       (select id from persona where account_id = '00000000-0000-0000-0000-00000000000b'),
       'welcome to the staff room', 'public', :'sid', :'staff';
select is(
  (select count(*)::int
   from community_channel_feed(:'staff', now() + interval '1 hour', 50)),
  1, 'community_channel_feed filters to one channel');
select is(
  (select channel_name
   from community_feed(:'sid', now() + interval '1 hour', 50)
   where channel_id = :'staff'),
  'Staff room', 'community_feed carries the channel name');

-- a plain member cannot post in a mods-only channel, but can in a members channel
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select throws_ok(
  format(
    $$insert into post (author_id, persona_id, body, visibility, community_id, channel_id)
      values ('00000000-0000-0000-0000-00000000000c',
              (select id from persona where account_id = '00000000-0000-0000-0000-00000000000c'),
              'sneaking in', 'public', %L, %L)$$,
    :'sid', :'staff'),
  '42501',
  'new row violates row-level security policy for table "post"',
  'a member cannot post in a mods-only channel');
select lives_ok(
  format(
    $$insert into post (author_id, persona_id, body, visibility, community_id, channel_id)
      values ('00000000-0000-0000-0000-00000000000c',
              (select id from persona where account_id = '00000000-0000-0000-0000-00000000000c'),
              'hi from a member', 'public', %L, %L)$$,
    :'sid', :'gen'),
  'a member can post in a members channel');
select throws_ok(
  format($$select create_channel(%L, 'x', 'X')$$, :'sid'),
  'only an admin can add channels', 'a non-admin cannot add a channel');

-- delete_channel: general is protected; other channels reparent their posts
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  format($$select delete_channel(%L)$$, :'gen'),
  'the general channel stays', 'the general channel cannot be deleted');
select delete_channel(:'staff');
select is(
  (select count(*)::int from community_channels(:'sid') where slug = 'staff'),
  0, 'delete_channel removes the channel');
select is(
  (select channel_id from post where body = 'welcome to the staff room'),
  :'gen'::uuid, 'a deleted channel''s posts fall back to general');

-- ── Phase 4-4b: events + RSVP ──────────────────────────────────────────
-- kid is an active member of secret-club (:'sid'); bob is its admin.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select create_event(:'sid', 'Book club', now() + interval '3 days', 'Chapters 4-6')
  as ev \gset
select is((select count(*)::int from community_events(:'sid')), 1,
  'create_event adds an upcoming event');
select is((select going_count from community_events(:'sid') where id = :'ev'),
  1, 'the creator is going by default');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select rsvp_event(:'ev', 'maybe');
select is((select maybe_count from community_events(:'sid') where id = :'ev'),
  1, 'rsvp_event records a maybe');
select is((select my_status from community_events(:'sid') where id = :'ev'),
  'maybe', 'my_status reflects the viewer''s own RSVP');
select is((select count(*)::int from event_attendees(:'ev', 'going')), 1,
  'event_attendees lists who is going');

-- a non-member cannot create an event
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select throws_ok(
  format($$select create_event(%L, 'gatecrash', now() + interval '1 day')$$, :'sid'),
  'only a member can create an event',
  'a non-member cannot create an event');

-- the creator can cancel; a canceled event can't be RSVP'd
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select cancel_event(:'ev');
select is((select canceled from community_events(:'sid') where id = :'ev'),
  true, 'cancel_event marks the event canceled');
select throws_ok(
  format($$select rsvp_event(%L, 'going')$$, :'ev'),
  'no such event', 'a canceled event cannot be RSVP''d');

-- ── Phase 4-5: community wiki ──────────────────────────────────────────
-- bob is admin of secret-club (:'sid'); kid is a plain member.
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select save_wiki_page(:'sid', 'welcome', 'Welcome', E'# Hi\n\nRead the rules.')
  as wp \gset
select is((select count(*)::int from community_wiki_pages(:'sid')), 1,
  'save_wiki_page creates a page');
select is((select title from wiki_page(:'sid', 'welcome')), 'Welcome',
  'wiki_page returns the page by slug');

select save_wiki_page(:'sid', 'welcome', 'Welcome!', 'Updated body', 'fixed title');
select is((select count(*)::int from wiki_page_history(:'wp')), 2,
  'each save snapshots a revision');
select is((select count(*)::int from community_wiki_pages(:'sid')), 1,
  'editing an existing slug does not create a second page');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select can_edit from wiki_page(:'sid', 'welcome')), false,
  'a plain member cannot edit the wiki');
select is((select title from wiki_page(:'sid', 'welcome')), 'Welcome!',
  'a member can read the wiki');
select throws_ok(
  format($$select save_wiki_page(%L, 'sneak', 'Sneak', '')$$, :'sid'),
  'only a moderator can edit the wiki',
  'a plain member cannot save a wiki page');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select set_wiki_pinned(:'wp', true);
select is((select is_pinned from wiki_page(:'sid', 'welcome')), true,
  'set_wiki_pinned pins the page');
select delete_wiki_page(:'wp');
select is((select count(*)::int from community_wiki_pages(:'sid')), 0,
  'delete_wiki_page removes the page');

-- ── Phase 4: richer discovery ──────────────────────────────────────────
-- :'cid' is rust-lang, topics {programming, rust}, listed.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from communities_browse('', 'rust')), 1,
  'communities_browse filters by topic tag');
select is((select count(*)::int from communities_browse('', 'no-such-topic')), 0,
  'a topic with no communities returns nothing');
select ok((select count(*)::int from community_topics()) >= 1,
  'community_topics lists the tags in use');

-- an NSFW community is hidden unless the caller opts in
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select create_community('after-dark', 'After Dark', '', array['rust'], 'open', true)
  as nsfw \gset
select is(
  (select count(*)::int from communities_browse('', null, 'active', false)
   where id = :'nsfw'),
  0, 'an NSFW community is hidden by default');
select is(
  (select count(*)::int from communities_browse('', null, 'active', true)
   where id = :'nsfw'),
  1, 'an NSFW community shows when the caller opts in');

-- ── Phase 5: search ────────────────────────────────────────────────────
-- alice's public post 'hello world' still exists; kid follows alice.
-- bob's 'friends only' circles post is not visible to kid.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select ok((select count(*) from search_posts('world')) >= 1,
  'search_posts finds a public post by word');
select is((select count(*)::int from search_posts('x')), 0,
  'search needs at least two characters');
select is((select count(*)::int from search_posts('friends')), 0,
  'search_posts respects post visibility (no circles post leak)');
select ok((select count(*) from search_all('world')) >= 1,
  'search_all returns a unified result set');

-- ── Phase 5: friends feed + "why am I seeing this?" ────────────────────
-- kid follows alice (not mutual yet); alice has a public post 'hello world'.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is(
  (select reason from feed_latest(now() + interval '1 hour')
   where author_handle = 'alice' limit 1),
  'You follow @alice', 'feed_latest says why a post is in the feed');
select is(
  (select count(*)::int from feed_friends(now() + interval '1 hour')
   where author_handle = 'alice'),
  0, 'feed_friends drops a non-mutual follow');

-- alice follows kid back (kid is a non-discoverable teen, so RLS would block a
-- normal follow — force it as the owner to set up the mutual edge)
set local role postgres;
insert into follow (follower_id, followee_id)
  values ('00000000-0000-0000-0000-00000000000a',
          '00000000-0000-0000-0000-00000000000c');

select tests.act_as('00000000-0000-0000-0000-00000000000c');
select ok(
  (select count(*) from feed_friends(now() + interval '1 hour')
   where author_handle = 'alice') >= 1,
  'feed_friends shows a mutual follow''s posts');
select is(
  (select reason from feed_friends(now() + interval '1 hour')
   where author_handle = 'alice' limit 1),
  'You and @alice follow each other', 'the reason names the mutual follow');

-- ── Phase 5: custom feeds ──────────────────────────────────────────────
select tests.act_as('00000000-0000-0000-0000-00000000000c');
insert into custom_feed (owner_id, name, rules)
values ('00000000-0000-0000-0000-00000000000c', 'Hellos',
        '{"any_words":["hello"]}'::jsonb)
returning id as cf \gset
select ok(
  (select count(*) from feed_custom(:'cf', now() + interval '1 hour')) >= 1,
  'feed_custom matches a keyword rule');

update custom_feed set rules = '{"not_words":["hello"]}'::jsonb where id = :'cf';
select is(
  (select count(*)::int from feed_custom(:'cf', now() + interval '1 hour')
   where id = :'alice_pub_id'),
  0, 'not_words excludes a matching post');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select throws_ok(
  format($$select feed_custom(%L)$$, :'cf'),
  'feed not found', 'a private custom feed is invisible to other users');

set local role postgres;
update custom_feed set is_public = true where id = :'cf';
select tests.act_as('00000000-0000-0000-0000-00000000000b');
select copy_custom_feed(:'cf') as cf2 \gset
select is(
  (select owner_id from custom_feed where id = :'cf2'),
  '00000000-0000-0000-0000-00000000000b'::uuid,
  'copy_custom_feed clones a public feed to the copier');

-- ── Phase 5: interests + people-you-may-know ───────────────────────────
-- kid follows alice; alice follows bob + kid; kid & bob share secret-club.
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select set_my_interests(array['space', 'music', 'BAD!!', '']);
select is((select count(*)::int from my_interests()), 2,
  'set_my_interests keeps only the valid topics');
select is(
  (select handle::text from people_you_may_know() limit 1),
  'bob', 'people_you_may_know surfaces a friend-of-friend / co-member');

select tests.act_as('00000000-0000-0000-0000-00000000000b');
select set_my_interests(array['rust', 'programming']);
select ok(
  (select count(*) from suggested_communities()) >= 1,
  'suggested_communities matches your interests to a community you are not in');

-- ── Phase 3: account deletion (last — purge_due_accounts is destructive) ──
select tests.act_as('00000000-0000-0000-0000-00000000000a');
select request_account_deletion();
select is(
  (select is_discoverable from profile where id = '00000000-0000-0000-0000-00000000000a'),
  false, 'request_account_deletion turns off discovery');

-- kid follows alice but a closing account is still hidden from profile_view
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from profile_view('alice')), 0,
  'a closing account is hidden from profile_view');

select tests.act_as('00000000-0000-0000-0000-00000000000a');
select cancel_account_deletion();
select is(
  (select deletion_requested_at from profile where id = '00000000-0000-0000-0000-00000000000a'),
  null, 'cancel_account_deletion clears the request');

-- purge only after the grace window
select tests.act_as('00000000-0000-0000-0000-00000000000c');
select request_account_deletion();
select is((select purge_due_accounts()), 0,
  'purge_due_accounts spares accounts still inside the 30-day grace');
set local role postgres;
update profile set deletion_requested_at = now() - interval '31 days'
  where id = '00000000-0000-0000-0000-00000000000c';
select ok((select purge_due_accounts()) >= 1,
  'purge_due_accounts removes accounts past the grace window');
select is(
  (select count(*)::int from profile where id = '00000000-0000-0000-0000-00000000000c'),
  0, 'purging an account cascades away its profile row');

select finish();
rollback;
