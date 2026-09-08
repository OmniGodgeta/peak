# Edge Functions

Deno functions for anything that needs secrets, heavy compute, or multi-step
integrity that RLS + triggers can't guarantee. See
[`../../docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) for the full list.

| Function     | Phase | Job                                                                            |
| ------------ | ----- | ------------------------------------------------------------------------------ |
| `publish`    | 1     | Validate a post, resolve mentions + circle audience, write the rows atomically |
| `media`      | 1     | Transcode, generate renditions/thumbnails/captions, strip EXIF                 |
| `push`       | 1     | Bundle notifications, deliver via FCM/APNs, respect quiet hours                |
| `fanout`     | 5     | Populate the per-recipient feed index                                          |
| `ranking`    | 5     | Score candidate feed items — **open, with excluded-signal tests**              |
| `feeds`      | 5     | Compile custom-feed rule sets to queries                                       |
| `moderation` | 4     | Report intake, enforcement + audit log, appeals, hash-match scanning           |
| `payments`   | 6     | Payment/payout webhooks, fee accounting                                        |
| `federation` | 7     | ActivityPub inbox/outbox, account `Move`                                       |
| `export`     | 3     | Build a user's full data archive                                               |

## Local dev

```bash
supabase functions serve publish --env-file ./supabase/.env.local
```

## Conventions

- TypeScript, Deno std where possible.
- No secret in a log line.
- Every function ships a happy-path test and an authz-failure test.
- Read the caller's identity from the verified JWT, never from the request body.
