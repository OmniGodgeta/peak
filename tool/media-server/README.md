# Peak media server

Holds the bytes for post images + video on **local disk** instead of Supabase
Storage, so the hosted project's storage/bandwidth quota isn't the ceiling
during the private beta. Postgres, Auth and RLS stay on hosted Supabase — this
server only stores and serves files for the public `post-media` bucket.

```
app ──upload (Bearer <supabase jwt>)──▶ peak-media ──▶ /run/media/.../peak-media/<user>/<uuid>.mp4
                                             │            + <uuid>.jpg (poster)
app ◀──────────  GET /v1/media/... (range)  ─┘
```

## What it does

- **Auth**: verifies the caller's Supabase access token against
  `SUPABASE_URL/auth/v1/user` (needs only the public anon key). No secret.
- **Video**: transcodes to a web-friendly MP4 (H.264 High / AAC, ≤1920px,
  `+faststart`) and extracts a poster frame. Probes width/height/duration.
- **Images**: stored as-is (GIF animation preserved); dimensions probed.
- **Serve**: `GET /v1/media/<user>/<file>` with HTTP range support + long cache
  + permissive CORS (the web app is a different origin).
- Per-user upload rate limit (20/min). Size caps: image 25 MB, video 500 MB.

## Setup (on the machine that keeps the files)

Needs `deno`, `ffmpeg`, `ffprobe`.

```bash
tool/media-server/setup.sh          # writes ~/.config/peak-media/env — edit it
tool/media-server/setup.sh          # run again: installs + starts the user service
```

Then expose it on the tailnet (you run this — `tailscale serve` is blocked in
Claude's session):

```bash
tailscale serve --bg --https 8790 http://127.0.0.1:8787
```

And point the app at it — add to `app/env.json` and the web build env:

```
--dart-define=PEAK_MEDIA_URL=https://shadow-1.tail51f9d6.ts.net:8790/v1
```

If `PEAK_MEDIA_URL` is unset the app falls back to Supabase Storage, so nothing
breaks before this is up.

## Ops

- `journalctl --user -u peak-media -f` — logs
- `curl http://127.0.0.1:8787/v1/health` — `{"ok":true}` (503 if the drive is
  unmounted)
- Files live under `MEDIA_ROOT/<user-uuid>/`. Deleting a Peak post does **not**
  delete the file yet (orphans just sit on disk) — a sweep is a TODO.
- `MEDIA_ROOT` on `/run/media/...` only exists while the drive is mounted and a
  session is active. For a permanent setup, mount it via `/etc/fstab` at a
  stable path and update `env`.

## Not yet

- Adaptive HLS (progressive MP4 + range is fine for the beta)
- EXIF strip on images
- Orphan cleanup on post delete
- Auth on the serve path (public, like Supabase public URLs — the path is the
  capability)
