# Edge Functions

Deno functions for anything that needs secrets, heavy compute, or multi-step
integrity that RLS + triggers can't guarantee. See
[`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) for the full list.

| Function             | Phase | Job                                                                                                                                                                                                                                                                                                                            |
| -------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `publish`            | 1     | Validate a post, resolve mentions + circle audience, write the rows atomically                                                                                                                                                                                                                                                 |
| `media`              | 1     | Transcode, generate renditions/thumbnails/captions, strip EXIF                                                                                                                                                                                                                                                                 |
| `push`               | 1     | _(superseded by `push-dispatch`)_ Bundle notifications, respect quiet hours                                                                                                                                                                                                                                                    |
| `fanout`             | 5     | Populate the per-recipient feed index                                                                                                                                                                                                                                                                                          |
| `ranking`            | 5     | Score candidate feed items — **open, with excluded-signal tests**                                                                                                                                                                                                                                                              |
| `feeds`              | 5     | Compile custom-feed rule sets to queries                                                                                                                                                                                                                                                                                       |
| `moderation`         | 4     | Report intake, enforcement + audit log, appeals, hash-match scanning                                                                                                                                                                                                                                                           |
| `payments`           | 6     | Payment/payout webhooks, fee accounting                                                                                                                                                                                                                                                                                        |
| `federation`         | 7     | ActivityPub server: WebFinger, NodeInfo, actors, outbox, notes; signed inbox (Follow/Undo/Like/Create/Delete/Accept/Reject/Update/Move) with HTTP Signature + actor checks; `/api/*` for the app (follow, unfollow, move). `verify_jwt=false`. Dormant until `FEDERATION_BASE_URL` + the flag are set.                         |
| `federation-deliver` | 7     | Drains `federation_job`: builds, signs (rsa-sha256) and delivers activities, shared-inbox deduped, blocked servers skipped, retries with backoff. pg_cron every minute.                                                                                                                                                        |
| `export`             | 3     | Build a user's full data archive                                                                                                                                                                                                                                                                                               |
| `ingest-content`     | 5     | Mirror public space feeds (ESA/Webb, ESA/Hubble, NASA/Roman, Launch Library 2) into Peak as posts by `@webb`/`@hubble`/`@roman`/`@launches`. `verify_jwt=false`; runs on the service role; pg_cron every 6h. Dedup in `content_ingest_seen`.                                                                                   |
| `purge-media`        | 3     | Drain `media_pending_delete` through the Storage API (SQL can't delete from `storage.objects`). pg_cron daily at 04:47, after `purge-deletions`. Only removes paths the database already queued.                                                                                                                               |
| `push-dispatch`      | 1     | Push notifications over UnifiedPush/Web Push (no FCM/APNs). Drains `push_queue` every minute (pg_cron) — bundled per person, deferred past quiet hours — and rings DM calls on demand (`{"ring":…}` with the caller's JWT, checked by `call_ring_targets`). Payloads RFC 8291-encrypted to the device; SSRF-guarded endpoints. |

## Local dev

```bash
supabase functions serve publish --env-file ./supabase/.env.local
```

## Conventions

- TypeScript, Deno std where possible.
- No secret in a log line.
- Every function ships a happy-path test and an authz-failure test.
- Read the caller's identity from the verified JWT, never from the request body.
