# Peak — notes for the next agent

Peak is a private Flutter + Supabase app at this repo. It is for personal use.
It will not go on the Play Store. Do not add payments, subscriptions, tips,
payouts, a storefront, or legal documents. Do not register a domain.

## Do not destroy data

- Never run `supabase db reset` or `supabase stop`. Apply schema with
  `supabase migration up` from the repo root.
- The app uses the local database. `app/env.json` is gitignored. Do not commit
  it or any key. Stage named files only. Never `git add -A`.
- `delete_post` only sets `deleted_at`. The post stays restorable for 30 days.
  Do not delete storage objects in that window. After 30 days,
  `purge_expired_deletions()` records bucket paths and hard-deletes the posts.
  `tool/purge_expired_media.py` removes those objects through the Storage API.
  SQL is not allowed to `DELETE` from `storage.objects`.
- Leave null-aware map entries as they are (`'community_id': ?communityId`).
  They omit the key when the value is null.
- Do not delete or replace methods in `app/lib/data/feed_repository.dart`.
  `latest`, `trending`, `friends`, `local`, `recommendations`, `thread`, and
  `videos` must stay.
- Ranking ignores likes, replies, reposts, and follower counts. Latest does
  not read boosts. Teens do not see boosted posts.
- The bottom nav label is Space. Database and Dart types stay named
  `community`. Community Guidelines stays the legal title.

## Preview

Web only, unless someone asks for an APK. From `app/`:

```
~/development/flutter/bin/flutter build web --release --dart-define-from-file=/tmp/peak-preview-env.json
rsync -a --delete build/web/ /home/shadowswords/peak-web/
systemctl --user restart peak-web
```

The temp env file is a copy of `app/env.json` whose `SUPABASE_URL` is
`https://shadow-1.tail51f9d6.ts.net:8721`. Delete that temp file. Do not
print keys. The page is `http://127.0.0.1:8730` (Tailscale
`https://shadow-1.tail51f9d6.ts.net:8720`). A 200 response is the old build
unless `Last-Modified` is newer than the edit. Do not rsync from the
Tailscale host. Build on this machine.

`flutter analyze --fatal-infos` must exit 0 before a commit. Commit style is
`feat:` or `fix:` with a body. Push to `origin main`.

**Release (operator instruction, 2026-09-25 - supersedes any older "don't
release" note in this file's history):** once a real chunk of backlog work
is done and verified, cut a release: bump `version:` in `app/pubspec.yaml`
(name+code, e.g. `1.1.0+20`), commit, then `git tag vX.Y.Z && git push
origin vX.Y.Z`. `.github/workflows/release.yml` picks up the tag, builds a
signed APK via the repo's GitHub secrets, and publishes the GitHub Release
itself - there is no local signing/build/`gh release create` step to do by
hand. Never overwrite an existing tag/release; always a new version.

## Done on main (updated 2026-09-25 - the list below this had gone stale;
verified item by item against `git log`, not assumed)

Phases 0–4. Phase 5 complete, including label appeals + a 90-day count
(`2a657e7`, `20261006000000_label_appeals.sql`). Phase 6 without money:
personas, Discover-only boosts, opt-in reach.

The viewer slice is done: `getPlaylistEntries` fixed (mirrors the correct
`getWatchLaterPosts` pattern via `post_thread`, not a raw embed), a real
"name this playlist" dialog, and Playlists/Watch Later linked into the Me
tab (`ffac78b`). A kanban worker had claimed this done earlier while making
zero actual changes to the repo (verified via empty `git log`/`reflog`/
`stash list`) - implemented directly instead.

Every numbered item below this that used to say "still to build" is done:

1. `author_is_verified` carried through feeds/profiles/threads; "see less"
   hides the reason without becoming a like-based ranker (`c4dbff2`,
   `5d6702f`).
2. Notice quiet hours + bundling (`20261007000000_notice_bundling_and_quiet_hours.sql`).
3. Composer writes polls, drafts, scheduling, `quote_of` (`9ee7509`, wired
   into the composer in `d89010a`).
4. Voice notes (record/send/play, `d92aa3c`) and disappearing messages
   (`429553e`) are real - not the `ceeeeb8` stubs this section used to warn
   about, which are gone.
5. Mute with a duration (`cbfaae8`), a temporary harassment shield
   (`0a8d766`, plus hiding posts during it: `d676776`), hiding posts during
   an account's 30-day deletion grace (`c4828c1`), a language filter +
   saved searches (`6144696`), story replies as DMs (`f204ae8`), and a
   reaction set beyond like (`c3ceff2`). **Passkeys were deliberately
   skipped**, not missed - a prior operator decision recorded in kanban
   history says so explicitly; don't build them without being asked again.
6. **Local 1:1 audio calls** are real (`8965079`): WebRTC signaled over a
   Supabase Realtime broadcast channel per call room (same mechanism
   `MessagingRepository.conversationChannel` uses for typing), STUN only
   (no TURN - calls between two devices both behind restrictive NAT may not
   connect), wired into 1:1 DM chats via a call button + an in-app
   incoming-call dialog. No push notification for calls, so the callee has
   to already have the chat open. **Not yet built: "live rooms"** - a
   multi-party room inside a Space. `call_rooms`/`call_participants`
   already support it (`space_id`, `max_participants`), but the UI/glare-
   avoidance logic only handles exactly 2 participants right now.
7. Federation (ActivityPub outbound function, WebFinger, account export/
   deletion controls - `a6c9158`) exists behind `federation_enabled = false`
   by default. **This was built ahead of the "wait until asked" project
   rule; the operator said "leave it as is for now" - do not extend it
   (inbound federation, cross-instance follow, account migration) without
   being asked again.**

Also on main:

- Bottom nav says Space. More spaces exist. Home feed can show public videos.
  In-app like, reply, and follow notices exist.
- JPEG and PNG uploads are re-encoded in `app/lib/data/media_service.dart`,
  which drops EXIF and GPS. GIFs are unchanged. Playback is still the mp4
  files. Adaptive HLS was not built.
- `post_chapters`, `post_subtitles`, `playlist`, `playlist_item`,
  `watch_later`, and `get_user_videos` exist. Chapter and caption reads follow
  the post audience. Only the author can write them.
- A profile Videos section calls `get_user_videos`. The author can open an
  editor to save chapters and captions. Thumbnails still use the raw storage
  path. Use `MediaService.resolveUrl`. The editor does not set `poster_path`
  yet (`updatePosterPath` exists and is unused).

`docs/ROADMAP.md` and `docs/HANDOFF.md` are older than this file. Trust this
file for status, and the roadmap for the original feature list - but check
the roadmap's Phase 9 (Video) and Phase 8 (Calls/events) sections too, since
this file only tracked the original "Still to build" numbered list and both
of those roadmap phases have real remaining items not in that list.

## Still to build

Development continues. Payments, a storefront, and lawyer review stay out.

- **Channels** (Phase 9: subscribe to a creator, browse their videos, an Up
  Next list on the watch page) - in progress as of 2026-09-25, check
  `git log` for whether it landed; if not, `video_subscription` table +
  `toggle_video_subscription`/`channel_subscriber_count`/
  `is_subscribed_to_channel` RPCs are the planned schema, not yet applied.
- **Live rooms** (Phase 8): a multi-party room inside a Space, building on
  the 1:1 call infra above. The 2-party offerer/answerer role logic will
  need real renegotiation for a 3rd+ participant (SDP glare becomes a real
  problem beyond 2 parties) - don't just loop the existing 1:1 code.
- Phase 9 remainder: a first-class `video` entity if reusing `post` gets
  strained, adaptive HLS + a CDN (real infra decision, not a code task),
  "why this video" ranking (needs real usage data first).
- Phase 7 federation remainder (inbound delivery, cross-instance follow/
  post/reply/like, account migration, instance allow/block transparency) -
  **do not start this without being asked**, per the operator's standing
  instruction above.

Skip payments and anything a lawyer has to sign.

## Known traps

- `supabase/functions/fanout-executor/index.ts` reads
  `community_member.user_id`. The column is `member_id`. Its global mode
  writes the feed for every profile. The live path is the SQL trigger that
  fans out to followers only. Do not point Latest at that function.
- Hosted project `izvcozvfqmggyziaeeoc` does not match local migration
  history. Develop against the local database.
- `app/v1.0.1_web_build.tar.gz` is already in git. Do not commit new build
  output.
