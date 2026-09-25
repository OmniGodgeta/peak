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
`feat:` or `fix:` with a body. Push to `origin main`. Do not create or
overwrite a GitHub release.

## Done on main

Phases 0–4. Phase 5 except labeler appeals and a transparency count: ranking
without engagement, follower fan-out, For You, verified check on Latest and
For You. Phase 6 without money: personas, Discover-only boosts, opt-in reach.

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
- `app/lib/data/viewer_repository.dart` can create playlists and watch-later
  rows. `getPlaylistEntries` embeds `post:media.post_id` and then calls
  `FeedPost.fromMap`. That embed is not a feed row and will throw. Nothing
  shipped calls it. Fix it before a screen uses it.

`docs/ROADMAP.md` and `docs/HANDOFF.md` are older than this file. Trust this
file for status, and the roadmap for the original feature list.

## Still to build

The local agent was told to finish the viewer screens, push them, and stop.
As of that instruction, `app/lib/features/media/viewer_screens.dart` was an
untracked scaffold: playlist names, watch-later ids with no titles, and an
Up Next placeholder. Those screens were not linked from `MediaScreen` or the
router. Resume position on the device was not stored.

After that slice, in this order:

1. Finish viewer UI if the push is still a scaffold. Playlists, watch-later
   with real titles, up-next the viewer opens, resume position on the device,
   posters through `MediaService.resolveUrl`. Fix `getPlaylistEntries` first.
2. Labeler appeals (a person can file one, staff queue with a stated response
   time) and a staff-visible count of enforcement actions. Carry
   `author_is_verified` through Friends, Local, custom feeds, space feeds,
   profiles, and threads. One-tap "see less of this" must not become a
   like-based ranker.
3. Notice quiet hours, bundling, and a neutral dot instead of a count badge.
   Push can be a local stub. Do not invent Firebase credentials.
4. Composer: polls, drafts, scheduling, quote-posts, reply and quote controls,
   a language tag, deliberate alt text, and visible edit history.
5. Voice notes and disappearing messages. MLS only if `rustup` and `cargo-ndk`
   are installed. Do not invent a fake crypto layer.
6. Smaller gaps that need no domain: passkeys if local auth supports them,
   mute with a duration, a temporary harassment shield, hide posts of an
   account inside its 30-day deletion grace, a language filter, saved
   searches, story replies as DMs, and a small reaction set beyond the like.
7. Local audio calls and live rooms. No storefront.
8. Federation code behind a flag that defaults off. No public port. No
   ActivityPub until someone asks.

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
