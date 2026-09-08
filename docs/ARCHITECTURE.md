# Architecture

## Guiding constraints

1. **No lock-in, structurally.** Every backend component is open source and self-hostable.
   Supabase is Postgres + open-source services; if we outgrow hosted Supabase we run the
   same stack ourselves.
2. **The database is the API.** Postgres schema + Row-Level Security is the primary
   authorization boundary. The client talks to PostgREST/Realtime directly for most reads
   and simple writes; Edge Functions handle anything that needs secrets, heavy compute,
   or multi-step integrity.
3. **The client is honest.** No analytics/ad SDKs. CI enforces a dependency denylist.
4. **E2E where it counts.** DMs are end-to-end encrypted; the server sees ciphertext.

## High-level diagram

```
┌────────────────────────────────────────────────────────────┐
│  Flutter app  (iOS · Android · Web PWA)                     │
│  ├─ feature modules: feed, compose, messaging, communities, │
│  │  discovery, profile, settings                            │
│  ├─ data layer: Supabase client (auth, PostgREST, Realtime, │
│  │  Storage), local cache (Drift/SQLite), secure key store  │
│  └─ crypto: MLS client (FFI to OpenMLS), local key material │
└───────────────┬────────────────────────────────────────────┘
                │ HTTPS / WSS
┌───────────────▼────────────────────────────────────────────┐
│  Supabase (hosted first, self-hosted later)                 │
│  ├─ Auth (GoTrue)          passkeys, OAuth, email           │
│  ├─ PostgREST              CRUD over the schema, RLS-guarded │
│  ├─ Realtime               feed/chat/notification streams   │
│  ├─ Storage (S3-compat)    media, with image/video transform│
│  └─ Edge Functions (Deno)  ranking, fan-out, media pipeline,│
│                            payments, push, moderation,      │
│                            federation bridge, export        │
└───────────────┬────────────────────────────────────────────┘
                │
┌───────────────▼───────────┐   ┌───────────────────────────┐
│  Postgres                 │   │  External / later          │
│  core schema + RLS        │   │  ├─ Search (Meilisearch)   │
│  materialized feed views  │   │  ├─ CDN for media          │
│  pg_cron jobs             │   │  ├─ Push (FCM / APNs)      │
│  pgvector (recs, Phase 5) │   │  ├─ Payments (Stripe +…)   │
└───────────────────────────┘   │  ├─ SFU for calls (Phase 8)│
                                │  └─ ActivityPub peers      │
                                └───────────────────────────┘
```

## Client

- **Flutter**, single codebase for iOS / Android / Web. Web target ships as an installable
  PWA with offline shell.
- **State/architecture**: Riverpod for DI + state; feature-first module layout under
  `app/lib/features/<feature>/`; a thin `app/lib/data/` wrapping the Supabase client and
  the local store.
- **Local persistence**: Drift (SQLite) for the offline cache of feed items, drafts,
  message history (ciphertext + locally decrypted plaintext), and settings. Drafts and
  settings are local-first and sync up.
- **Secure storage**: `flutter_secure_storage` (Keychain / Keystore) for tokens and MLS
  key material.
- **Media**: `cached_network_image`, range-request video; data-light mode swaps to
  low-res renditions and disables prefetch.
- **Routing**: `go_router`, deep-link + universal-link ready for share URLs and
  federation handles.

## Backend

### Auth
GoTrue. Passkeys (WebAuthn) preferred; email+password and Apple/Google OAuth supported.
JWT carries `sub` (user id) and custom claims (`persona_id`, `is_teen`, role flags).
RLS policies read these claims.

### Data access
- **Reads**: mostly direct PostgREST/Realtime, constrained by RLS. Feed reads hit
  materialized/rollup tables, not raw joins.
- **Writes**: simple writes (like, follow, post to a circle) go direct with RLS + triggers
  enforcing invariants. Complex writes (publish with fan-out, payments, moderation
  actions, federation) go through Edge Functions.

### Edge Functions (Deno, `supabase/functions/`)
| Function | Job |
|---|---|
| `publish` | Validate a post, resolve circle audience, enqueue fan-out |
| `fanout` | Write feed-index rows / invalidate caches for recipients (pg queue + `pg_cron`) |
| `ranking` | Score candidate feed items for non-chronological feeds; **open, tested against excluded-signal assertions** |
| `feeds` | Evaluate custom-feed rule sets into candidate sets |
| `media` | Transcode video, generate renditions + thumbnails + captions, strip EXIF |
| `push` | Bundle notifications, deliver via FCM/APNs, respect quiet hours |
| `moderation` | Hash-match scanning, report intake, enforcement + audit log, appeals |
| `payments` | Stripe (and regional processors) webhooks, payouts, fee accounting |
| `federation` | ActivityPub inbox/outbox, signature verify, account `Move` (Phase 7) |
| `export` | Build a user's full data archive (ActivityStreams JSON + media) |

### Feed model
- **Latest / Friends-first** (Phase 1): query-time, reverse-chronological over a
  `follow`-derived author set, with circle-visibility filtering in the query. Cheap.
- **Non-chronological** (Phase 5): a **fan-out-on-write feed index** (`feed_item` rows per
  recipient) populated by `fanout`, then `ranking` scores a candidate window at read time.
  Hybrid: celebrity accounts (huge follower counts) are fan-out-on-read to avoid write
  amplification.
- **Custom feeds** (Phase 5): `feeds` compiles a rule set to a SQL filter / pgvector query;
  results cached briefly.

### Messaging
- Transport: a `message` table (ciphertext, sender, conversation, timestamps, ordering
  key) + Realtime channel per conversation. Server-side RLS restricts to conversation
  members.
- Crypto: **MLS (RFC 9420)** via OpenMLS compiled to a native lib, called over FFI from
  Flutter. Server stores and relays MLS messages + key packages; never holds group keys.
- Disappearing messages: client enforces + a `pg_cron` sweep hard-deletes expired rows.

### Notifications
- `notification` rows + Realtime for in-app; `push` Edge Function bundles and sends.
- Default: neutral dot, daily digest option, quiet hours, per-type controls.

### Search (Phase 5)
Postgres FTS to start (`tsvector` columns + GIN). Move hot paths to **Meilisearch** or
**Typesense** when needed; index only content the searcher is allowed to see (per-doc ACL
tags).

### Recommendations (Phase 5)
`pgvector` embeddings for posts, communities, interests. Candidate generation =
approximate-NN + graph features; scoring in `ranking`. No behavioural surveillance
features (dwell, rage-clicks) as inputs — enforced by test.

### Federation (Phase 7)
`federation` Edge Function implements ActivityPub server-to-server. Local posts get
signed, content-addressed IDs. Account migration follows Mastodon's `Move`/`Alias` flow so
followers transfer.

## Data protection

- RLS on **every** table; deny-by-default; policies reviewed in PRs that touch schema.
- Media URLs are signed and short-lived; originals stripped of EXIF/GPS on upload.
- Retention windows enforced by `pg_cron` jobs, documented in `docs/PRODUCT.md §9`.
- Backups encrypted; deletion propagates to backups within the stated window.
- Secrets only in Edge Functions (Supabase Vault), never in the client or the DB.

## Environments

| Env | Backend | Purpose |
|---|---|---|
| local | `supabase start` (Docker) | dev, tests |
| preview | ephemeral Supabase branch per PR | review apps |
| staging | dedicated project | pre-release, load tests |
| production | dedicated project → self-hosted cluster | the reference instance |

## Scaling path (when hosted Supabase isn't enough)

1. Read replicas + PgBouncer; push feed indexes to their own replica.
2. Move media to a dedicated S3 + CDN.
3. Self-host the Supabase stack on Kubernetes; Postgres via Patroni or a managed
   Postgres; Realtime horizontally scaled.
4. Partition `feed_item` and `message` by time; cold-storage old partitions.
5. Regional instances that federate, rather than one global monolith.

## Key technology choices & rationale

| Choice | Why | Alternative considered |
|---|---|---|
| Flutter | One codebase, matches existing tooling, good perf, strong web | React Native, native ×2 |
| Supabase | Open source, self-hostable, Postgres+RLS is a real authz model, fast start | Firebase (lock-in), bespoke (slow) |
| Postgres + RLS as authz | One enforcement point, auditable, hard to bypass | app-layer checks (leak-prone) |
| MLS for DMs | Group-scalable forward secrecy, an actual RFC | Signal protocol (pairwise, weaker at group scale) |
| ActivityPub | Largest existing federated network, real migration story | AT Protocol, Nostr |
| AGPL-3.0 | A social network that can be quietly closed isn't open | MIT (permits a closed fork) |
