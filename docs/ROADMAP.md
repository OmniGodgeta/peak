# Roadmap

Phases are sequenced by dependency, not calendar. Each phase ends with something
demonstrable. "Done" means: shipped to the reference instance, documented, tested,
accessible.

> **Picking up work?** Start with [HANDOFF.md](HANDOFF.md) — current state, what's
> blocked on the operator, and the immediate next tasks.

**Status (2026-10):** phases 0–4 done. Phase 5 ~90% (labelers, custom feeds +
directory, local feed, interests/PYMK, search, wellbeing, reports,
proof-of-personhood, Discover populated with graph-free "popular communities" +
"fresh on Peak" all shipped; ranking Edge Function + fan-out index + pgvector
recs remain). Hosted Supabase backend is live. Feed video (post + inline player)
shipped basic — no server-side transcoding yet.

**Peak is a private beta right now.** No public domain (`@name@peak.social`
handles are baked in, so the domain must be chosen before real users sign up).
Reachable only on the operator's Tailscale preview + a sideloaded APK. The
mirror/news accounts (@webb, @playstation, @scinews, …) keep the feed and
communities alive for a small tester group. Going public is gated on the
operator items in [HANDOFF.md §4a](HANDOFF.md) (domain, auth URL config, a
lawyer pass on the legal drafts), not on more features.

### Near-term punch-list (before "going public")

Not a phase — the concrete work between here and a public launch:

- **Finish Phase 5's buildables**: ranking Edge Function (open, excluded-signal
  tests), fan-out-on-write feed index, pgvector "For you", personhood/labeler
  badges on post cards.
- **Video polish**: server-side transcode + poster frames + size renditions
  (the "media pipeline" gap), a duration/really-large-file guard, moderation
  reach for video.
- **Operator**: register the domain → Cloudflare Pages web host + real email
  (Resend); lawyer pass on `docs/legal/*`; Turnstile on signup.
- **Content hygiene**: a light review queue for the mirror feeds; per-source
  on/off switches; drop dead feeds.

---

## Phase 0 — Foundation  ·  *in progress*

Goal: a developer can clone, run the app against a local backend, and sign in.

- [x] Repo, license, docs, CI skeleton
- [x] Branding: Peak mark → app icons; dark-first theme from the palette
- [x] Schema: `profile`, `profile_private`, `persona`, `circle`, `circle_member`,
      `follow`, `block`, `mute`, `mute_word` — all RLS deny-by-default
- [x] `bootstrap_account` RPC: handle + DOB (13+ enforced) + 5 system circles
- [x] Federation-shaped handles (`@name@peak.social`), age-derived teen accounts
- [x] App shell: go_router, dark/light/high-contrast theme, Riverpod, Supabase wiring
- [x] Auth (email) + onboarding (handle, display name, date of birth)
- [x] Profile view (read)
- [x] RLS policy tests (pgTAP, 66 assertions) + `supabase test db` green in CI
- [x] Profile edit (avatar, bio, links, pronouns)
- [x] CI running green (Flutter + Supabase schema + Edge Functions jobs)
- [x] Public backend: **hosted Supabase live** (2026-09-10) — project
      `izvcozvfqmggyziaeeoc`, all 41 migrations applied, `pg_cron` + `pg_net`,
      retention jobs + `ingest-content` (every 6h) scheduled,
      `app-version` / `export` / `publish` / `ingest-content` edge functions
      deployed. The Tailscale preview web now points at it. Domain + public web
      host still deferred — see [DEPLOY.md](DEPLOY.md) §1–2.
- [x] Seed directory + automated space feeds (`tool/seed-directory.sql`,
      `ingest-content`) — house `@peak`; `@webb` / `@hubble` / `@roman`
      (ESA/NASA imagery) + `@launches` (Launch Library 2) mirror accounts;
      communities `c/space` `c/gaming` `c/rockets` `c/science` `c/astrophotos`.
- [ ] Self-hosting the stack on `shadow` remains an option later — see
      [SELF_HOSTING.md](SELF_HOSTING.md)
- [ ] Passkey + OAuth sign-in (email works today)

## Phase 1 — MVP feed

Goal: post to a circle, follow people, read a chronological feed. This is the smallest
thing that is recognizably "a social network."

- [x] `post`, `post_audience`, `post_media`, `reaction`, `repost`, `mention` tables + RLS
- [x] `feed_latest` RPC + `can_view_post` visibility function
- [x] Composer: text + circle picker + CW + photos with alt-text
- [x] `publish` Edge Function (mentions resolved server-side)
- [x] **Latest** feed; "You're caught up" marker
- [x] Likes (counts private by default), threaded replies + thread view, reposts
- [x] Block (real semantics) + mute + mute-words in the visibility helpers
- [x] Teen-account defaults (private, not discoverable)
- [x] Delete a post → 30-day recyclable bin (see Phase 3 data controls)
- [~] Composer: alt-text is a soft prompt; polls, drafts, scheduling, quote-posts to do
- [ ] Media upload pipeline (EXIF strip, renditions, thumbnails) — needs `shadow`
- [x] **Friends-first** feed variant — `feed_friends` (only people who follow
      you back); the home feed toggle now actually swaps the query
- [ ] Notifications (in-app + push, bundled, quiet hours, neutral badge)
- [x] Report content/account → moderation intake — `report` table +
      `report_reason`/`report_status`; `submit_report` (post / profile /
      community / message; dedup per reporter; CSAM / self-harm / violence
      flagged urgent); a `staff` table + `is_staff`/`am_i_staff`; `review_queue`
      (site staff see all, a community mod sees non-urgent reports about their
      community) + `resolve_report`. Report actions on post cards, profiles, and
      communities; "Your reports" + a moderation queue screen under Me. CSAM
      still needs the manual NCMEC step (docs/DEPLOY.md §6).

## Phase 2 — Messaging

Goal: talk to people privately.

- [x] `conversation`, `conversation_member`, `message` + RLS
- [x] 1:1 and group chat over Realtime; media, reactions via edit/delete
- [x] Typing indicators (opt-in), read receipts (both-sides opt-in), edit/delete-for-everyone
- [x] Message requests (non-connections land in a request state)
- [ ] Voice notes
- [ ] Disappearing messages + `pg_cron` sweep

### Phase 2.5 — E2E encryption (MLS, multi-device)

Full design: [ENCRYPTION.md](ENCRYPTION.md). Staged:

- [x] **2.5-0** — design + schema (`device`, `key_package`, `mls_*`,
      `history_blob`, `conversation.e2ee`), `claim_key_packages` RPC,
      `E2eeService` seam with the no-op impl
- [ ] **2.5-1** — native OpenMLS build (cargo-ndk + xcframework) + `dart:ffi`
      bindings + local round-trip smoke test *(needs the Rust toolchain)*
- [~] **2.5-2** — device registration + Devices screen shipped (pure-Dart
      Ed25519 identity key); real key-package generation waits on 2.5-1
- [ ] **2.5-3** — MLS group per new conversation; encrypt/decrypt application
      messages; feature flag on for new conversations
- [ ] **2.5-4** — membership/device changes (Add/Remove/Update + Commit),
      epoch handling, key rotation
- [ ] **2.5-5** — encrypted history archive + new-device restore + recovery phrase
- [ ] **2.5-6** — key-verification / safety-number screen + device-list
      transparency check
- [ ] **2.5-7** — migrate or label the remaining transport-only DMs; flip default

## Phase 3 — Rich media, stories, articles, data controls  ·  *in progress*

- [x] **One-click data export** — `export_my_data()` + `export` Edge Function →
      signed archive link; AS2-shaped posts, graph, messages, devices
- [x] **Real delete** — `delete_post` → 30-day "recently deleted" bin →
      `restore_post`; `purge_expired_deletions()` sweep (needs a `pg_cron` schedule)
- [x] Account deletion: request → profile hidden + can't post → 30-day grace
      (sign back in to cancel) → `purge_due_accounts()` cascade. Hiding a
      closing account's *old posts* mid-grace is a follow-up (shares the
      moderation-suspend primitive, Phase 5).
- [x] Long-form articles — a post with a title + a big body, its own reading
      page with a tiny built-in Markdown renderer (headings, lists, paragraphs);
      replies/reactions/circle visibility all inherited from `post`
- [x] Stories — a photo + caption addressed to circles, gone after 24h; a
      full-screen viewer (tap to step, hold to pause, auto-advance); a plain
      viewer list for the author. No filters, no streaks. `purge_expired_stories()`
      sweep (hourly cron).
- [x] Profile highlights — pin up to 5 of your own posts to the top of your profile
- [x] Data-light mode — per-device toggle; images load on tap
- [~] Video posts — **basic shipped**: pick one clip (≤60s / ≤50 MB) in the
      composer, uploaded as-is to the `post-media` bucket (`kind: 'video'`),
      inline tap-to-play player (scrub + mute, honours data-light) in the feed.
      **Not yet**: server-side transcode to adaptive renditions, poster frames,
      EXIF/metadata strip, audio-only posts — that's the "media pipeline", which
      wants real storage + a CDN ([SELF_HOSTING.md](SELF_HOSTING.md)).

Phase 3 is complete bar the full media pipeline (transcode + CDN + audio posts),
which arrives with the `shadow` self-host.

## Phase 4 — Communities  ·  *in progress*

- [x] **4-0** — `community` / `community_member` (+ role/state enums); `post`
      gains `community_id`; `can_view_post` + `post_insert` learn about
      community posts; `create_community` / `join_community` / `leave_community`
      / `community_view` / `communities_browse` / `my_communities` /
      `community_feed`. Communities tab (directory + your communities), a
      community page with its feed + join/leave, a "create community" flow,
      and community-scoped posting in the composer.
- [x] **4-1** — request approval, member roster, role management (mod / admin,
      last-admin protection), remove / ban / unban; a Manage screen + admin
      "edit community"
- [x] **4-2** — `community_mod_log` (member-readable, every mod action logged
      with an optional reason); `post_label` — a moderator labels a post
      ("off-topic", …) instead of removing it; `moderate_remove_post`; a mod
      log screen + post-card label chip + moderator controls
- [x] **4-3** — rules-on-join + member flair (`community_rule`,
      `set_community_rules` / `community_rules` / `set_my_flair`; rules shown on
      the community page, a flair chip, flair on community posts). Modmail
      (`modmail_thread` / `modmail_message`, `start_modmail` / `modmail_reply` /
      `set_modmail_state`, `my_modmail_threads` / `community_modmail_threads` /
      `modmail_messages`) — a private member↔mod-team thread, kept out of the
      public mod log; a banned member can still open one to appeal. Member entry
      point on the community page + "Moderator messages" in the profile; a
      per-community queue (open / closed / all) in Manage.
- [x] **4-4** — text channels (`community_channel` + `channel_post_policy`;
      every community has `#general`; `post.channel_id` with a trigger that
      defaults it / inherits it on replies; `post_insert` learns channels;
      mods-only channels for announcements; `community_channels` /
      `create_channel` / `update_channel` / `delete_channel` (posts fall back to
      general) / `reorder_channels`; `community_channel_feed`; a channel strip on
      the community page + an admin Channels screen). Events + RSVP
      (`community_event` / `event_rsvp` + `rsvp_status`; `create_event` /
      `update_event` / `cancel_event` / `rsvp_event`; `community_events` /
      `event_attendees`; can be scoped to a channel; going/maybe/not-going;
      client-side .ics + Google Calendar link; an events list, a detail page
      with the RSVP bar + attendee list, and a create/edit form). Voice later.
- [x] **4-5** — community wiki + pinned resources (`community_wiki_page` +
      `community_wiki_revision`; every save snapshots a revision; a page can be
      pinned to the community front page; moderators edit, members read;
      `community_wiki_pages` / `wiki_page` / `wiki_page_history` /
      `save_wiki_page` / `delete_wiki_page` / `set_wiki_pinned`; a wiki list, a
      page view reusing the tiny Markdown renderer, an editor, and a history
      view; a "Resources" block on the community page)
- [x] Richer discovery directory — `communities_browse` gains a topic filter,
      a sort (most active / newest / largest), an NSFW opt-in, and activity
      signal (last post, posts in the last 7 days); `community_topics` lists the
      tags in use. Directory screen has a sort menu, an 18+ toggle, and topic
      filter chips. (Language filter deferred — no per-post language yet.)

## Phase 5 — Ranking, custom feeds, discovery, moderation depth  ·  *~90%*

- [ ] Fan-out-on-write feed index + hybrid path for large accounts
- [ ] `ranking` Edge Function — open, with excluded-signal test suite
- [~] **"Why am I seeing this?"** — `feed_latest` / `feed_friends` return a
      `reason` string ("You follow @x" / "You and @x follow each other" / "Your
      post"); the post-card menu item now shows it. Gets richer once ranking
      lands.
- [x] Custom feeds (rule sets, shareable) — `custom_feed` (name + jsonb
      rules: communities / from / any_words / not_words / only_media) +
      `feed_custom` compiler (still gated by `can_view_post`); `copy_custom_feed`
      clones a public one (recording `copied_from`). The home feed switcher
      lists your custom feeds; a Manage-feeds screen with a rule editor. Feed
      directory (`custom_feeds_browse` / `custom_feed_meta`, popular/new sort,
      copy-count) + share-by-link (`peak.social/f/<id>`, "add from link").
- [~] Interests + People-you-may-know — `profile_interest` (+ `set_my_interests`
      / `my_interests`); `people_you_may_know` (friend-of-friend + co-member
      only, with the reason); `suggested_communities` (listed communities
      matching your interests / your communities' topics). Discover landing:
      interests editor, **Popular communities** and **Fresh on Peak** (both
      graph-free, so a brand-new account still sees content), PYMK,
      communities-for-you.
- [x] Local feed — `feed_local` (every public, top-level, non-community post on
      the instance, newest first; post RLS + your mutes still apply). In the
      Home feed switcher next to Latest / Friends first. "Here" widens with
      federation later.
- [~] Search (Postgres FTS) with per-doc ACL — `post.search_vector` generated
      `tsvector` + GIN index; `search_posts` (rank blended with recency, still
      gated by `can_view_post`) and `search_all` (people + communities + posts
      in one ranked list). The Discover tab is now unified search with
      People / Communities / Posts filters. Meilisearch swap-in later if needed.
- [ ] pgvector recommendations
- [~] **User-level labelers** (stackable, subscribable) — `labeler` / `labeler_label`
      (`info`/`warn`/`hide` severity) / `content_label` / `labeler_subscription`;
      `create_labeler` / `set_labeler_labels` / `apply_content_label` /
      `subscribe_labeler` / `labelers_browse` / `post_labels_for_me`. Post cards
      render the labels from labelers you own or subscribe to; a `hide` label
      blurs the post behind a tap-to-reveal, always attributed. Me → Labelers to
      run your own or subscribe. Still to do: appeals SLA + quarterly
      transparency report.
- [x] Proof-of-personhood badges — `personhood` (method `staff` | `vouch`) +
      `personhood_vouch`; a staff grant, or 3 vouches from already-verified
      people (auto-granted, auto-revoked below the threshold). `vouch_for` /
      `unvouch` / `personhood_of` / `my_vouches` / `grant_personhood` /
      `revoke_personhood` / `personhood_pending`. `profile_view` carries
      `is_verified_person` / `personhood_method` / `vouch_count`; a ✓ badge on
      profiles, a vouch button, Me → Proof of personhood. Deliberately not
      identity verification. (Post-card badge: a later pass across the feed RPCs.)
- [x] Wellbeing suite — per-device (never the account): a session clock that
      resets after a real break; a "take a break" sheet at 15/30/60 min
      ("no streaks, no penalty for leaving"); always-on greyscale; quiet hours
      (greyscale + hide like/reply counts on a schedule). Settings under
      Me → Wellbeing.

## Phase 6 — Creators (money is a later, separate decision)

The promise is **no ads, ever**. How Peak sustains itself is deliberately left
open — Peak is fully usable without any of it, and this phase should not block a
public launch. Ship the creator features that don't touch money first; treat
payments as a decision to revisit once there's a real community asking for it
(and once federation raises the "who takes a cut across instances?" question).

**Now-ish (no money):**
- [ ] Multiple personas per login (schema already supports `persona`; needs UI)
- [ ] Boosting for **Discover only**, always labelled; never affects followers' Latest
- [ ] Creator analytics without dark patterns (your own reach, opt-in)

**Deferred — decision pending (money):**
- [ ] Payments integration (a processor + at least one regional option)
- [ ] Subscriptions, tips, paid/paywalled posts; consented subscriber-list export
- [ ] Payouts + fee accounting (flat, transparent) — or a non-transactional model
      (donations to the instance, grants, member co-op) if that fits better

> Rationale for the split: monetisation is the part most likely to compromise the
> product if rushed. Everything else in Peak — feed, communities, DMs, video,
> federation — works and launches without it.

## Phase 7 — Federation

- [ ] ActivityPub server-to-server (`federation` Edge Function)
- [ ] Follow / post / reply / like across instances
- [ ] Account migration in & out (Mastodon `Move` + follower carry-over)
- [ ] Instance allow/block transparency; signed content-addressed posts

## Phase 8 — Calls, events at scale, marketplace

- [ ] 1:1 and group voice/video (WebRTC + SFU), screen share, live captions
- [ ] Larger events / live audio rooms
- [ ] Creator storefront (digital goods, merch via partners)
- [ ] Community memberships (paid)

## Phase 9 — Peak Video (a searchable video destination)

A dedicated place to publish and discover longer-form video — the YouTube-shaped
pillar. Distinct from feed video clips: these are titled, described, searchable,
and have their own watch page. Detail: [PRODUCT.md §13](PRODUCT.md).

- [ ] `video` schema: title, description, tags, duration, chapters, captions, visibility
- [ ] Upload pipeline: resumable upload, transcode to adaptive renditions (HLS),
      poster frames, auto-captions, thumbnail selection
- [ ] Storage + CDN for video (this is the point Supabase Storage alone stops being enough)
- [ ] Watch page: adaptive player, chapters, captions, description, comments (reuse `post` replies), up-next
- [ ] Channels: a creator's video collection on their profile; subscribe
- [ ] Video search (title/description/caption/tag) + a Video tab in Discover
- [ ] Ranking that stays honest: no autoplay-into-the-void, no "recommended" rabbit
      holes by default; "why this video?" like the feed
- [ ] Monetization ties into Phase 6 (subscriptions, tips, paid videos) — never ads
- [ ] Playlists; watch-later; resume-where-you-left-off (local-first)

---

## Cross-cutting, every phase

- Accessibility review before each release (screen reader, captions, contrast, reduced motion)
- Security review for anything touching auth, RLS, crypto, payments, or federation
- Localization keys kept current; RTL sanity check
- Dependency denylist stays green (no analytics/ad SDKs)
- Load test the new hot path

## Open questions

Tracked in [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md).
