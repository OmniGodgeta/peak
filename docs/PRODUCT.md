# Product specification

This is the full feature catalogue — the "add all your suggestions" document. Items are
tagged with the roadmap phase that introduces them (see [ROADMAP.md](ROADMAP.md)). Nothing
here is final; it's the menu we cook from.

---

## 1. Accounts & identity

### 1.1 Sign-up — *Phase 0*
- Email + password, or passkey (WebAuthn), or OAuth (Apple/Google) — OAuth is a
  convenience, never required.
- **No real-name policy.** Display name is free text; handle is `@name`.
- Pseudonymous accounts are first-class, not second-class.

### 1.2 Proof-of-personhood *(optional badge)* — *Phase 5*
- Tiered, opt-in:
  - **Device-attested human** — passes device integrity + rate/behaviour checks. Free, no ID.
  - **ID-verified** — one-time government-ID check via a third party that returns only
    yes/no + age band; we never store the document.
- A badge signals "a real person stands behind this account," decoupled from fame.
- Bots must self-label; unlabelled automation is a bannable offence.

### 1.3 Circles — *Phase 1*
- Every account has editable circles. Defaults: **Close Friends, Friends, Family, Work,
  Public.** Users add their own (e.g. "Climbing", "D&D group").
- A contact can be in several circles.
- **Every post is addressed to one or more circles.** "Public" is just another circle.
- Circles are private — no one can see which of your circles they're in.

### 1.4 Multiple personas *(later)* — *Phase 6*
- One login can hold several personas (e.g. personal + a project account) with fast
  switching, shared billing, no cross-linking exposed to others.

### 1.5 Profile — *Phase 1*
- Avatar, banner, bio, links (with optional rel-me verification), pronouns field,
  location (as coarse as the user wants), joined date.
- **Follower / following counts hidden by default**, per-account toggle to show.
- Pinned posts. Profile "shelves" — curated collections (Phase 3).
- "Also me elsewhere" — verified links to other federated accounts.

---

## 2. The feed

### 2.1 Named feeds — *Phase 1 (chronological), Phase 5 (custom)*
Feed switcher at the top of Home. Ships with:
- **Latest** — pure reverse-chronological from people/communities you follow. Always present, never removable.
- **Friends first** — chronological but people in your closer circles float up; no hidden down-ranking.
- **Discover** — recommendations, clearly labelled as such, easy to turn off.
- **Custom feeds** — user- or community-authored feeds defined by readable rules
  (keywords, authors, communities, media type, language, "has alt text", min/max length).
  Shareable. Think Bluesky custom feeds.

### 2.2 Ranking principles — *Phase 5*
- The default non-chronological ranking optimizes for a blend of:
  - affinity (how much you interact *reciprocally* with the author),
  - recency,
  - your explicit signals (follows, circle, mutes, "more/less like this"),
  - **"worth your time"** — a post-session lightweight prompt ("was your feed worth it
    today?") plus per-post "glad I saw this / didn't need this" that feed back into ranking.
- It explicitly does **not** use dwell time, rage-click proxies, or notification-return
  rate as positive signals.
- All ranking code lives in `supabase/functions/ranking/` and is covered by tests that
  assert the excluded signals stay excluded.

### 2.3 "Why am I seeing this?" — *Phase 5*
Every non-chronological item has an overflow action that shows the actual reasons:
"From @x, who you DM often · posted 2h ago · you follow 3 people who liked it ·
matches your 'cycling' interest." With one-tap "see less of this / mute this reason."

### 2.4 Anti-doomscroll — *Phase 1*
- **No infinite autoplaying scroll by default.** After ~30 items: a "You're caught up"
  card with the option to load more.
- **Digest mode** — opt in to one or two assembled catch-ups a day instead of a live feed.
- Autoplay video **off by default**; tap to play; captions on by default.
- Optional on-screen session timer and a soft nudge at a user-set limit.
- No "X new posts" jitter pulling you back to the top mid-read.

### 2.5 Post composer — *Phase 1+*
- Types: text, photo (multi), video, audio note, link, poll, long-form article (Phase 3),
  event (Phase 4).
- **Circle picker is mandatory** and remembered per session.
- Alt-text prompt for every image; "post without alt text" requires a deliberate tap.
- Content warning / spoiler field; sensitive-media flag.
- Schedule for later; save drafts (local-first, synced).
- Edit window with a visible "edited" marker and history.
- Language tag (auto-detected, editable) for per-language feeds.
- **Reply controls** per post: everyone / people I follow / circle / mentioned only / nobody.
- **Quote controls**: allow / ask / disallow quote-posts.

### 2.6 Reactions & replies — *Phase 1*
- Like plus a small fixed reaction set (no reaction inflation).
- **Like counts private by default**, author can reveal per post; "hide all counts from
  me" global reader setting.
- Threaded replies with sane collapsing.
- **Reactions never generate a notification storm** — batched.

### 2.7 Reposts — *Phase 1*
- Repost (no comment) and quote-post (with comment), both respecting the original's controls.
- "Reposts from people I follow" is a toggle, not forced.

---

## 3. Stories — *Phase 3*
- 24h ephemeral, addressed to a circle (Close Friends by default).
- **No beauty-retouch filters.** Creative filters/stickers/text yes; face-slimming/skin-smoothing no.
- No "seen by" pressure: viewer list is available to the author but there are no read receipts pushed to viewers, and no streaks.
- Reply to a story = a normal DM.
- Highlights = save a story to a profile shelf.

---

## 4. Messaging — *Phase 2 (transport), Phase 2.5 (E2E)*

### 4.1 Direct & group chat
- 1:1 and group (up to a few hundred) chat over Realtime.
- **End-to-end encrypted by default** using **MLS** (RFC 9420) for group-scalable
  forward secrecy. Server stores ciphertext + minimal routing metadata only.
- Media, voice notes, reactions, replies, typing indicators (per-chat toggle).
- **Disappearing messages** per chat (off / 24h / 7d / 30d).
- Read receipts **off by default**, mutual opt-in.
- Edit & delete-for-everyone with a tombstone.
- Message requests inbox for non-connections; nothing from a non-connection notifies you
  until you accept.
- No cloud backup of plaintext; encrypted export with a user-held key.

### 4.2 Calls — *Phase 8*
- 1:1 and group voice/video over WebRTC (SFU), E2E where group size allows.
- Screen share, raise hand, live captions.

---

## 5. Communities — *Phase 4*
Reddit × Discord hybrid. A community has:
- Its own **feed** (posts, following the same composer/circle-free but rule-bound model),
- Its own **chat channels** (text/voice),
- **Events**, a **wiki**, and **pinned resources**,
- **Roles & permissions**, member flair,
- **Rules** shown on join; **modmail**; **transparent mod log** (who removed what and why,
  visible to members),
- **Labels not just removals** — mods can attach a label ("off-topic", "unverified",
  "satire") instead of deleting,
- Join: open / request / invite.
- Discovery directory with topic tags, size, activity, language, and "safe for work" flag.

---

## 6. Discovery — *Phase 5*
- **Interests**, not tracking: you pick topics; recommendations explain themselves.
- **Local** tab (opt-in, coarse geo) for events and nearby communities.
- **Events** — RSVP, reminders, calendar export, recurring, online/in-person.
- **People you may know** based only on mutual follows and shared communities —
  never on contact-list scraping, location history, or off-platform data.
- Full-text **search** across posts you're allowed to see, people, communities, events,
  with filters; saved searches; "search within a feed".

---

## 7. Creators & money — *Phase 6*
- **Subscriptions** — monthly support tiers with perks (subscriber-only posts/circles/chat).
- **Tips** — one-off, on any post or profile.
- **Paid posts / paywalled long-form.**
- **Flat ~5% platform fee** (plus payment processor pass-through). No 30% cut.
- **Payouts** weekly, low minimum, multiple regions/currencies.
- **Own your audience**: export subscriber list with contact emails (consented), so a
  creator can survive us disappearing.
- **No pay-to-reach**: a creator's followers always see their posts in Latest. Boosting
  only affects Discover, and boosted content is labelled.
- Analytics that report reach and engagement **without** dark-pattern "your reach dropped,
  post more!" nagging.
- Later: **storefront** (digital goods, merch via partners), **memberships for communities.**

---

## 8. Safety, moderation & wellbeing

### 8.1 Blocking & muting — *Phase 1*
- **Block is real**: a blocked account cannot see your profile, posts, or that you exist
  in listings; cannot follow, DM, mention, quote, or view via the API while logged in.
- Mute (you stop seeing them, they don't know), with a duration option.
- **Mute words / phrases / hashtags**, with duration, applied across feed + notifications.
- **Import/subscribe to block lists** (community-curated).
- **Harassment shield** — temporary mode: hide replies/DMs/mentions from accounts that
  are new, don't follow you, or aren't in a circle.

### 8.2 Moderation model — *Phase 4–5*
- **Layered:**
  1. Instance-level rules (illegal content, spam, CSAM scanning via hash-matching,
     coordinated inauthentic behaviour).
  2. Community-level moderation by that community's mods.
  3. **User-level labelers** — subscribe to independent labeling services (à la Bluesky)
     that annotate/hide categories you don't want. Stackable, swappable.
- **Transparency**: every enforcement action gives a reason and a specific rule; every
  action is appealable to a human; aggregate enforcement stats published quarterly.
- **Labels over deletion** wherever possible (context, not erasure).
- Appeals SLA published and measured.

### 8.3 Teen accounts (13–17) — *Phase 1 defaults, hardened Phase 5*
- Private by default; not discoverable by adults who aren't connections.
- No DMs from non-connections; no message requests from adults.
- No beauty filters; no streaks; no manipulative retention notifications.
- Screen-time tools on by default; quiet hours default overnight.
- Ad-free is moot (no ads) but also: no "sponsored/boosted" content shown to teens at all.

### 8.4 Wellbeing — *Phase 5*
- Session awareness ("you've been scrolling 20 min").
- "Take a break" and scheduled quiet hours.
- No red notification-count badge by default — a neutral dot; full counts opt-in.
- Notification bundling and a single daily "here's what you missed".
- Optional **greyscale mode** on a schedule.

---

## 9. Privacy & data

### 9.1 Defaults — *Phase 0–1*
- No third-party analytics or ad SDKs in the app. Ever. CI fails if one is added.
- First-party, privacy-preserving product analytics only (aggregate, no per-user
  behavioural profiles, opt-out honoured).
- No contact-list upload. No location history. No off-platform tracking pixels.
- Minimal metadata retention; documented retention windows per data type.

### 9.2 User controls — *Phase 3*
- **One-click export**: posts, media, messages (encrypted), graph, settings — as a
  standard archive (ActivityStreams JSON + files).
- **Real delete**: deleting content removes it from live systems immediately and from
  backups within a stated window; a "recently deleted" bin for accidental deletes.
- Per-item audience always visible and changeable after posting.
- "Who can find me by email / phone" — default nobody.
- Account deletion is immediate-suspend + 30-day grace + purge.

### 9.3 Federation — *Phase 7*
- Speaks **ActivityPub**; interoperates with Mastodon, Threads (if it federates), etc.
- **Account migration** in and out (Mastodon-style `Move` + follower carry-over).
- Instance blocklist/allowlist transparency for the reference instance.
- Signed, content-addressed posts so migration keeps history.

---

## 10. Accessibility & reach — *Phase 1 onward*
- Full screen-reader support; every interactive element labelled; tested each release.
- Auto-captions for video/audio, editable by the author.
- Alt-text encouraged by flow, surfaced to everyone, searchable.
- Dynamic type, high-contrast theme, reduced-motion honoured everywhere.
- **Data-light mode** — lower-res media, no prefetch, text-first — for expensive/slow networks.
- Full localization; RTL; per-language feeds.
- Works as a fast PWA on low-end Android.

---

## 11. Platform & ecosystem
- **Open API** (the same PostgREST + Edge API the app uses) with humane rate limits.
- **Webhooks** and an **app/bot framework** with clear scopes and a review process; bots labelled.
- Third-party clients explicitly allowed and encouraged.
- **Self-hosting**: `docker compose up` gets you a working instance; docs for scaling.

---

## 12. Explicitly rejected

- Advertising, "sponsored posts", influencer-marketing infrastructure aimed at users.
- Selling or brokering user data; "data partnerships".
- Engagement-optimized default ranking.
- Infinite scroll + autoplay as defaults.
- Streaks, manipulative notifications, fake urgency.
- Beauty/retouch filters on faces.
- Real-name enforcement.
- Shadow profiles of non-users.
- Crypto tokens / "web3" / engagement mining.
- Hiding a creator's posts from their own followers unless they pay.
