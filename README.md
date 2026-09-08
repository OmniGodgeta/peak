# ShadowChat

**An open, human-first social network.** Feed, messaging, and communities in one app —
built to be everything Facebook and Instagram should have been, and none of what they became.

> Status: **Phase 0 — Foundation.** Not usable yet. Building in the open from commit one.

---

## Why another social network?

The incumbents optimize for one number: time-on-app. Everything follows from that —
outrage-amplifying feeds, infinite scroll, addictive notification loops, ads that follow
you across the web, opaque moderation, creators who don't own their audience, and a
walled garden you can't leave with your data or your friends.

ShadowChat is built on the opposite premise: **your attention is yours, your data is
yours, and your social graph is yours.** We make money from people choosing to pay us,
not from advertisers renting your behavior.

### What makes it different

| | Facebook / Instagram | ShadowChat |
|---|---|---|
| **Business model** | Targeted ads, data brokering | No ads, ever. Optional subscription + low creator fees + self-host licensing |
| **The feed** | One opaque algorithm optimizing engagement | You pick the feed. Chronological, Friends-first, or custom rule-based feeds. Ranking code is open source |
| **"Why am I seeing this?"** | No real answer | Every ranked item explains itself |
| **Your data** | Hard to export, impossible to move | One-click full export in open formats; account + follower portability |
| **DMs** | Scanned, metadata retained | End-to-end encrypted by default (MLS); minimal metadata |
| **Identity** | One name for everyone in your life | Circles are first-class — Close Friends / Family / Work / Public per post |
| **Bots** | Everywhere | Proof-of-personhood option, pseudonymity still allowed (no real-name rule) |
| **Openness** | Closed, hostile to third-party clients | AGPL-3.0, open API, self-hostable, federates over ActivityPub |
| **Creators** | 30–50% cuts, reach throttled unless you pay | ~5% flat fee, own your subscriber list, no pay-to-reach-your-own-followers |
| **Teens** | Engagement-maxed, beauty filters, streaks | Private by default, no manipulative retention mechanics, screen-time awareness |
| **Deletion** | "Deleted" ≠ gone | Delete means delete, with a visible retention window |

Full detail: **[docs/PRODUCT.md](docs/PRODUCT.md)**

---

## The app

A single **Flutter** app for **iOS, Android, and Web (PWA)**. Four pillars:

1. **Feed** — text, photo, video, audio, and long-form posts; stories; all targeted to a circle.
2. **Messaging** — E2E 1:1 and group chat, voice/video calls, disappearing messages.
3. **Communities** — topic spaces with their own feeds, chat, events, and wikis (Reddit × Discord).
4. **Discovery** — custom feeds, local and interest discovery, events.

Backend is **Supabase** (Postgres + Auth + Realtime + Storage + Edge Functions) — fully
open source and self-hostable, so the reference instance is never a lock-in.

Architecture: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** ·
Roadmap: **[docs/ROADMAP.md](docs/ROADMAP.md)**

---

## Repo layout

```
shadowchat/
├── app/                 Flutter application (iOS / Android / Web)
├── supabase/            Database schema, migrations, Edge Functions, config
├── docs/                Vision, product spec, architecture, roadmap
└── .github/workflows/   CI
```

---

## Getting started (developers)

Prerequisites: Flutter ≥ 3.47, Node ≥ 20, Docker (for local Supabase), the
[Supabase CLI](https://supabase.com/docs/guides/cli).

```bash
# 1. Start a local backend (Postgres, Auth, Storage, Realtime) in Docker
cd supabase
supabase start
supabase db reset          # applies migrations + seed

# 2. Run the app against it
cd ../app
cp .env.example .env        # fill in the URL + anon key printed by `supabase start`
flutter pub get
flutter run                 # or: flutter run -d chrome
```

See **[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)** for the full workflow, coding
standards, and how to pick up an issue.

---

## License

**[AGPL-3.0](LICENSE).** If you run a modified ShadowChat server, you must share your
changes. This is deliberate: a social network that can be quietly closed isn't open.

Security disclosures: **[docs/SECURITY.md](docs/SECURITY.md)**.
