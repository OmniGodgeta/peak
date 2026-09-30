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
- **Video**: transcodes to a web-friendly MP4 (H.264 High 8-bit 4:2:0 / AAC, ≤1920px,
  `+faststart`) and extracts a poster frame. Probes width/height/duration.
- **Audio**: any of m4a/aac/mp3/ogg/webm/wav → AAC 128k in `.m4a` (metadata
  stripped); duration probed. Used by audio-only posts.
- **Images**: stored as-is (GIF animation preserved); dimensions probed.
- **Serve**: `GET /v1/media/<user>/<file>` with HTTP range support + long cache
  + permissive CORS (the web app is a different origin).
- **Adaptive streaming (HLS)**: after each video upload a 360p/720p/1080p
  ladder (never upscaled; video-only if the clip has no audio) is built in the
  background, one at a time, into `<user>/<id>/master.m3u8`. The upload
  answer carries `hlsUrl`; phones try it first and fall back to the MP4
  until it's ready (web always uses the MP4 — only Safari plays HLS
  natively). `HLS=off` disables it on a slow box. Older videos:
  `MEDIA_ROOT=… deno task backfill-hls` (idempotent).
- **Poster from a frame**: `POST /v1/poster` `{"path":"<user>/<id>.mp4","tMs":12000}`
  grabs that frame as a new thumbnail. Only the caller's own videos.
- Per-user upload rate limit (20/min). Size caps: image 25 MB, video 500 MB, audio 100 MB.

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
--dart-define=PEAK_MEDIA_URL=https://retroverse.tail51f9d6.ts.net:8790/v1
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

- Deleting files of purged posts (the 30-day purge only queues Supabase
  Storage paths; media-server files stay on disk). Images are EXIF-stripped
  client-side before upload.
- A CDN: this box is tailnet-only, so a public CDN can't front it. That's a
  hosting decision for when Peak has a public home.
- Auth on the serve path (public, like Supabase public URLs — the path is the
  capability)
