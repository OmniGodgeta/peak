// Peak media server — stores post images + video on local disk instead of
// Supabase Storage, so the hosted project's storage/bandwidth quota isn't the
// ceiling during the private beta.
//
// It does NOT replace Supabase: Postgres, Auth and RLS stay hosted. This server
// only holds the bytes for the public `post-media` bucket. It authenticates
// uploads with the caller's Supabase access token (verified against the hosted
// project's /auth/v1/user endpoint — no secret needed) and serves files back
// over HTTP with range support.
//
// Run:  deno task start           (see deno.json / peak-media.service)
// Env:  MEDIA_ROOT   absolute dir for the files (a drive with room)
//       PUBLIC_BASE  the URL this server is reachable at, incl. /v1
//                    e.g. https://shadow-1.tail51f9d6.ts.net:8790/v1
//       SUPABASE_URL, SUPABASE_ANON_KEY   the hosted project (token check)
//       PORT         listen port (default 8787, bind 127.0.0.1)
//       MAX_IMAGE_MB (default 25)  MAX_VIDEO_MB (default 500)

import { serveFile } from "jsr:@std/http@1/file-server";
import { join, normalize } from "jsr:@std/path@1";

const MEDIA_ROOT = must("MEDIA_ROOT");
const PUBLIC_BASE = must("PUBLIC_BASE").replace(/\/+$/, "");
const SUPABASE_URL = must("SUPABASE_URL").replace(/\/+$/, "");
const SUPABASE_ANON_KEY = must("SUPABASE_ANON_KEY");
const PORT = Number(Deno.env.get("PORT") ?? "8787");
const MAX_IMAGE = Number(Deno.env.get("MAX_IMAGE_MB") ?? "25") * 1024 * 1024;
const MAX_VIDEO = Number(Deno.env.get("MAX_VIDEO_MB") ?? "500") * 1024 * 1024;

const CORS: HeadersInit = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type, x-peak-kind",
  "Access-Control-Expose-Headers":
    "content-range, content-length, accept-ranges",
};

const IMAGE_EXT: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/avif": "avif",
};
const VIDEO_EXT: Record<string, string> = {
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "video/webm": "webm",
  "video/x-matroska": "mkv",
};

await Deno.mkdir(MEDIA_ROOT, { recursive: true }).catch(() => {});

// ── crude per-user upload rate limit ─────────────────────────────────────
const hits = new Map<string, { n: number; reset: number }>();
function rateLimited(key: string): boolean {
  const now = Date.now();
  const e = hits.get(key);
  if (!e || now > e.reset) {
    hits.set(key, { n: 1, reset: now + 60_000 });
    return false;
  }
  e.n++;
  return e.n > 20;
}

Deno.serve({ port: PORT, hostname: "127.0.0.1" }, async (req) => {
  const url = new URL(req.url);
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

  if (url.pathname === "/v1/health") {
    let root = true;
    try {
      await Deno.stat(MEDIA_ROOT);
    } catch {
      root = false;
    }
    return json({ ok: root, mediaRootMounted: root }, root ? 200 : 503);
  }

  if (url.pathname === "/v1/upload" && req.method === "POST") {
    return await handleUpload(req);
  }

  if (url.pathname.startsWith("/v1/media/") && req.method === "GET") {
    return await handleServe(req, url.pathname.slice("/v1/media/".length));
  }

  return json({ error: "not found" }, 404);
});

console.log(`peak-media on 127.0.0.1:${PORT} → ${MEDIA_ROOT}`);

// ── upload ──────────────────────────────────────────────────────────────

async function handleUpload(req: Request): Promise<Response> {
  const auth = req.headers.get("authorization") ?? "";
  const userId = await verifyUser(auth);
  if (!userId) return json({ error: "unauthorized" }, 401);
  if (rateLimited(userId)) return json({ error: "slow down" }, 429);

  const ct = (req.headers.get("content-type") ?? "").split(";")[0].trim()
    .toLowerCase();
  const isVideo = ct in VIDEO_EXT;
  const isImage = ct in IMAGE_EXT;
  if (!isVideo && !isImage) {
    return json({ error: `unsupported content-type: ${ct}` }, 415);
  }

  const body = new Uint8Array(await req.arrayBuffer());
  const cap = isVideo ? MAX_VIDEO : MAX_IMAGE;
  if (body.byteLength === 0) return json({ error: "empty body" }, 400);
  if (body.byteLength > cap) {
    return json({ error: `too large (max ${cap / 1048576} MB)` }, 413);
  }

  const id = crypto.randomUUID();
  const dir = join(MEDIA_ROOT, userId);
  await Deno.mkdir(dir, { recursive: true });
  const srcExt = isVideo ? VIDEO_EXT[ct] : IMAGE_EXT[ct];
  const tmp = join(dir, `${id}.src.${srcExt}`);
  await Deno.writeFile(tmp, body);

  try {
    if (isVideo) {
      const out = join(dir, `${id}.mp4`);
      const poster = join(dir, `${id}.jpg`);
      await run([
        "ffmpeg",
        "-y",
        "-i",
        tmp,
        "-c:v",
        "libx264",
        "-profile:v",
        "high",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-vf",
        "scale='min(1920,iw)':-2",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        out,
      ]);
      await run([
        "ffmpeg",
        "-y",
        "-ss",
        "0.5",
        "-i",
        out,
        "-frames:v",
        "1",
        "-vf",
        "scale='min(1280,iw)':-2",
        "-q:v",
        "4",
        poster,
      ]).catch(() => {});
      await Deno.remove(tmp).catch(() => {});
      const probe = await probeMedia(out);
      return json({
        path: `${userId}/${id}.mp4`,
        url: `${PUBLIC_BASE}/media/${userId}/${id}.mp4`,
        posterUrl: await exists(poster)
          ? `${PUBLIC_BASE}/media/${userId}/${id}.jpg`
          : null,
        kind: "video",
        width: probe.width,
        height: probe.height,
        durationMs: probe.durationMs,
      });
    }

    // image: keep the bytes as-is (GIF animation intact); just probe dimensions
    const finalName = `${id}.${srcExt}`;
    await Deno.rename(tmp, join(dir, finalName));
    const probe = await probeMedia(join(dir, finalName)).catch(() => ({
      width: null,
      height: null,
      durationMs: null,
    }));
    return json({
      path: `${userId}/${finalName}`,
      url: `${PUBLIC_BASE}/media/${userId}/${finalName}`,
      posterUrl: null,
      kind: "image",
      width: probe.width,
      height: probe.height,
      durationMs: null,
    });
  } catch (e) {
    await Deno.remove(tmp).catch(() => {});
    return json(
      { error: `processing failed: ${e instanceof Error ? e.message : e}` },
      500,
    );
  }
}

// ── serve ───────────────────────────────────────────────────────────────

async function handleServe(req: Request, rel: string): Promise<Response> {
  // rel = "<userId>/<file>"; reject traversal and anything not two segments
  const clean = normalize(rel).replace(/^(\.\.(\/|\\|$))+/, "");
  const parts = clean.split("/").filter(Boolean);
  if (parts.length !== 2 || parts.some((p) => p.startsWith("."))) {
    return json({ error: "bad path" }, 400);
  }
  const abs = join(MEDIA_ROOT, parts[0], parts[1]);
  try {
    const stat = await Deno.stat(abs);
    if (!stat.isFile) throw new Error("not a file");
    const res = await serveFile(req, abs, { fileInfo: stat });
    for (const [k, v] of Object.entries(CORS)) res.headers.set(k, v);
    res.headers.set("Cache-Control", "public, max-age=31536000, immutable");
    return res;
  } catch {
    return json({ error: "not found" }, 404);
  }
}

// ── helpers ─────────────────────────────────────────────────────────────

async function verifyUser(authHeader: string): Promise<string | null> {
  if (!/^Bearer\s+.+/i.test(authHeader)) return null;
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: authHeader, apikey: SUPABASE_ANON_KEY },
    });
    if (!res.ok) return null;
    const user = await res.json();
    return typeof user?.id === "string" ? user.id : null;
  } catch {
    return null;
  }
}

async function run(cmd: string[]): Promise<void> {
  const p = new Deno.Command(cmd[0], {
    args: cmd.slice(1),
    stdout: "null",
    stderr: "piped",
  });
  const { code, stderr } = await p.output();
  if (code !== 0) {
    const msg = new TextDecoder().decode(stderr).split("\n").slice(-4).join(
      " ",
    );
    throw new Error(`${cmd[0]} exited ${code}: ${msg}`);
  }
}

interface Probe {
  width: number | null;
  height: number | null;
  durationMs: number | null;
}

async function probeMedia(path: string): Promise<Probe> {
  const p = new Deno.Command("ffprobe", {
    args: [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=width,height:format=duration",
      "-of",
      "json",
      path,
    ],
    stdout: "piped",
    stderr: "null",
  });
  const { stdout } = await p.output();
  const j = JSON.parse(new TextDecoder().decode(stdout));
  const s = j?.streams?.[0] ?? {};
  const dur = Number(j?.format?.duration);
  return {
    width: Number.isFinite(s.width) ? s.width : null,
    height: Number.isFinite(s.height) ? s.height : null,
    durationMs: Number.isFinite(dur) ? Math.round(dur * 1000) : null,
  };
}

async function exists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path);
    return true;
  } catch {
    return false;
  }
}

function must(name: string): string {
  const v = Deno.env.get(name);
  if (!v) {
    console.error(`missing env ${name}`);
    Deno.exit(1);
  }
  return v;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json", ...CORS },
  });
}
