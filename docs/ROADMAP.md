# Roadmap

Phases are sequenced by dependency, not calendar. Each phase ends with something
demonstrable. "Done" means: shipped to the reference instance, documented, tested,
accessible.

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
- [ ] Self-host the Supabase stack on `shadow` — see [SELF_HOSTING.md](SELF_HOSTING.md)
- [ ] Apply migrations to that instance; wire the app's `env.json` to it
- [ ] RLS policy tests (pgTAP) + `supabase test db` green in CI
- [ ] Passkey + OAuth sign-in (email works today)
- [ ] Profile edit (avatar, bio, links, pronouns)
- [ ] CI running green (workflow needs `workflow` scope on the gh token to push)

## Phase 1 — MVP feed

Goal: post to a circle, follow people, read a chronological feed. This is the smallest
thing that is recognizably "a social network."

- [x] `post`, `post_audience`, `post_media`, `reaction`, `repost`, `mention` tables + RLS
- [x] `feed_latest` RPC + `can_view_post` visibility function
- [~] Composer: text + circle picker + CW done; photos, alt-text flow, reply/quote
      controls, polls, drafts, scheduling still to do
- [ ] Route posting through the `publish` Edge Function (mentions + fan-out server-side)
- [ ] Media upload pipeline (EXIF strip, renditions, thumbnails)
- [ ] **Latest** feed (reverse-chronological) + **Friends-first** feed
- [ ] "You're caught up" marker; autoplay off; captions on
- [ ] Likes (counts private by default), reactions, threaded replies, reposts/quotes
- [ ] Block (real semantics) + mute + mute-words
- [ ] Teen-account defaults
- [ ] Notifications (in-app + push, bundled, quiet hours, neutral badge)
- [ ] Report content/account → moderation intake

## Phase 2 — Messaging

Goal: talk to people privately.

- [ ] `conversation`, `conversation_member`, `message` + RLS
- [ ] 1:1 and group chat over Realtime; media, voice notes, reactions, replies
- [ ] Typing indicators (opt-in), read receipts (opt-in), edit/delete-for-everyone
- [ ] Message requests inbox for non-connections
- [ ] Disappearing messages + `pg_cron` sweep

### Phase 2.5 — E2E encryption

- [ ] OpenMLS FFI binding for Flutter; key management in secure storage
- [ ] MLS group lifecycle (create, add/remove, key rotation) wired to conversations
- [ ] Server relays ciphertext + key packages only; migration of existing chats
- [ ] Encrypted local export with user-held key

## Phase 3 — Rich media, stories, articles, data controls

- [ ] Video posts (transcode, adaptive playback), audio posts
- [ ] Long-form articles in the composer
- [ ] Stories (24h, circle-addressed, no face-retouch filters, no streaks)
- [ ] Profile shelves / highlights
- [ ] **One-click data export** (ActivityStreams archive)
- [ ] **Real delete** + "recently deleted" bin + retention jobs
- [ ] Data-light mode

## Phase 4 — Communities

- [ ] `community`, `community_member`, `community_role`, channels, `community_post`
- [ ] Community feed + text/voice channels
- [ ] Roles & permissions, flair, rules-on-join, modmail
- [ ] **Transparent mod log** visible to members; labels-not-just-removals
- [ ] Events (RSVP, reminders, calendar export)
- [ ] Community wiki + pinned resources
- [ ] Discovery directory for communities

## Phase 5 — Ranking, custom feeds, discovery, moderation depth

- [ ] Fan-out-on-write feed index + hybrid path for large accounts
- [ ] `ranking` Edge Function — open, with excluded-signal test suite
- [ ] **"Why am I seeing this?"** on every ranked item
- [ ] Custom feeds (rule sets, shareable) + `feeds` compiler
- [ ] Interests, People-you-may-know (mutuals/communities only), local tab
- [ ] Search (Postgres FTS → Meilisearch) with per-doc ACL
- [ ] pgvector recommendations
- [ ] **User-level labelers** (stackable, subscribable) + appeals SLA + quarterly transparency report
- [ ] Proof-of-personhood badges
- [ ] Wellbeing suite (session awareness, greyscale schedule, take-a-break)

## Phase 6 — Creators & money

- [ ] Payments integration (Stripe + at least one regional processor)
- [ ] Subscriptions, tips, paid/paywalled posts
- [ ] Payouts, fee accounting (~5% flat), analytics without dark patterns
- [ ] Subscriber-list export (consented)
- [ ] Multiple personas per login
- [ ] Boosting for Discover only, always labelled; never affects followers' Latest

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

---

## Cross-cutting, every phase

- Accessibility review before each release (screen reader, captions, contrast, reduced motion)
- Security review for anything touching auth, RLS, crypto, payments, or federation
- Localization keys kept current; RTL sanity check
- Dependency denylist stays green (no analytics/ad SDKs)
- Load test the new hot path

## Open questions

Tracked in [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md).
