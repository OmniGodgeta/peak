// link-preview — fetch OpenGraph / oEmbed metadata for a URL in a post and
// cache it in `link_preview`. The app reads the cache directly on a hit and
// calls this only to fill a miss (or refresh a stale row).
//
// POST { "url": "https://…" }  →  { url, final_url, title, description,
//   image_url, site_name, kind: "link"|"video"|"youtube"|"photo", video_id }
//
// Safety: only http(s); the host (and every redirect hop) is DNS-resolved and
// rejected if it points at a private / loopback / link-local address (SSRF).
// Body read is capped and the whole fetch is time-boxed.

import { createClient } from "jsr:@supabase/supabase-js@2";

const MAX_BYTES = 512 * 1024;
const TIMEOUT_MS = 8000;
const MAX_REDIRECTS = 4;
const FRESH_DAYS = 7;
const UA =
  "Mozilla/5.0 (compatible; peak-social/1.0; +https://peak.social) link-preview";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let input: { url?: string };
  try {
    input = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const raw = (input.url ?? "").trim();
  let target: URL;
  try {
    target = new URL(raw);
  } catch {
    return json({ error: "bad url" }, 400);
  }
  if (target.protocol !== "http:" && target.protocol !== "https:") {
    return json({ error: "unsupported scheme" }, 400);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const key = raw;
  const { data: cached } = await db
    .from("link_preview")
    .select("*")
    .eq("url", key)
    .maybeSingle();
  if (
    cached &&
    Date.now() - new Date(cached.fetched_at).getTime() <
      FRESH_DAYS * 86_400_000
  ) {
    return json(cached);
  }

  let row: Record<string, unknown>;
  try {
    row = await build(key, target);
  } catch (e) {
    row = {
      url: key,
      ok: false,
      kind: "link",
      title: null,
      description: `unavailable: ${e instanceof Error ? e.message : e}`.slice(
        0,
        200,
      ),
    };
  }
  row.fetched_at = new Date().toISOString();
  await db.from("link_preview").upsert(row);
  return json(row);
});

// ── build the preview ────────────────────────────────────────────────────

async function build(
  key: string,
  target: URL,
): Promise<Record<string, unknown>> {
  // YouTube: don't even fetch — build from the id.
  const yt = youtubeId(target);
  if (yt) {
    return {
      url: key,
      final_url: target.toString(),
      kind: "youtube",
      video_id: yt,
      site_name: "YouTube",
      image_url: `https://i.ytimg.com/vi/${yt}/hqdefault.jpg`,
      title: await oembedTitle(target).catch(() => null),
      description: null,
      ok: true,
    };
  }

  const { finalUrl, contentType, html } = await safeFetch(target);

  if (/^(video|audio)\//.test(contentType) || isDirectMedia(finalUrl)) {
    return {
      url: key,
      final_url: finalUrl,
      kind: contentType.startsWith("audio/") ? "link" : "video",
      title: null,
      description: null,
      image_url: null,
      site_name: new URL(finalUrl).hostname,
      ok: true,
    };
  }

  const meta = parseMeta(html);
  return {
    url: key,
    final_url: finalUrl,
    // A page whose og:type is "video" but with no direct src still renders as a
    // link card (tap to open) — only YouTube / direct files play inline.
    kind: "link",
    title: meta["og:title"] ?? meta["twitter:title"] ?? meta["title"] ?? null,
    description: meta["og:description"] ?? meta["twitter:description"] ??
      meta["description"] ?? null,
    image_url: abs(meta["og:image"] ?? meta["twitter:image"], finalUrl),
    site_name: meta["og:site_name"] ?? new URL(finalUrl).hostname,
    video_id: null,
    ok: true,
  };
}

async function oembedTitle(u: URL): Promise<string | null> {
  const o = new URL("https://www.youtube.com/oembed");
  o.searchParams.set("url", u.toString());
  o.searchParams.set("format", "json");
  const res = await fetch(o, {
    headers: { "User-Agent": UA },
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) return null;
  const j = await res.json();
  return typeof j?.title === "string" ? j.title : null;
}

// ── fetch with redirect + SSRF guard ────────────────────────────────────

async function safeFetch(
  start: URL,
): Promise<{ finalUrl: string; contentType: string; html: string }> {
  let url = start;
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    await assertPublicHost(url);
    const res = await fetch(url, {
      redirect: "manual",
      headers: { "User-Agent": UA, "Accept": "text/html,*/*" },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      if (!loc) throw new Error("redirect without location");
      url = new URL(loc, url);
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`http ${res.status}`);
    }
    const contentType = (res.headers.get("content-type") ?? "").toLowerCase();
    if (/^(video|audio)\//.test(contentType)) {
      await res.body?.cancel();
      return { finalUrl: url.toString(), contentType, html: "" };
    }
    const html = await readCapped(res);
    return { finalUrl: url.toString(), contentType, html };
  }
  throw new Error("too many redirects");
}

async function readCapped(res: Response): Promise<string> {
  const reader = res.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (total < MAX_BYTES) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    total += value.byteLength;
  }
  await reader.cancel().catch(() => {});
  return new TextDecoder("utf-8", { fatal: false }).decode(
    concat(chunks).subarray(0, MAX_BYTES),
  );
}

function concat(chunks: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(chunks.reduce((n, c) => n + c.byteLength, 0));
  let o = 0;
  for (const c of chunks) {
    out.set(c, o);
    o += c.byteLength;
  }
  return out;
}

async function assertPublicHost(u: URL): Promise<void> {
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (/^(localhost|.*\.localhost|.*\.local|.*\.internal)$/i.test(host)) {
    throw new Error("blocked host");
  }
  const ips: string[] = [];
  if (isIp(host)) {
    ips.push(host);
  } else {
    for (const t of ["A", "AAAA"] as const) {
      try {
        ips.push(...await Deno.resolveDns(host, t));
      } catch { /* no record of that type */ }
    }
    if (ips.length === 0) throw new Error("host does not resolve");
  }
  for (const ip of ips) if (isPrivateIp(ip)) throw new Error("blocked address");
}

function isIp(s: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(s) || s.includes(":");
}

function isPrivateIp(ip: string): boolean {
  if (ip.includes(":")) {
    const l = ip.toLowerCase();
    // IPv4-mapped (::ffff:1.2.3.4) → check the embedded v4
    const mapped = l.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) return isPrivateIp(mapped[1]);
    return l === "::1" || l === "::" ||
      /^f[cd][0-9a-f]{2}:/.test(l) || // fc00::/7 ULA
      /^fe[89ab][0-9a-f]:/.test(l); // fe80::/10 link-local
  }
  const p = ip.split(".").map(Number);
  if (p.length !== 4 || p.some((n) => Number.isNaN(n) || n < 0 || n > 255)) {
    return true;
  }
  const [a, b] = p;
  return a === 0 || a === 10 || a === 127 ||
    (a === 100 && b >= 64 && b <= 127) || // CGNAT 100.64/10
    (a === 169 && b === 254) || // link-local
    (a === 172 && b >= 16 && b <= 31) || // 172.16/12
    (a === 192 && b === 168) ||
    a >= 224; // multicast / reserved
}

// ── parsing ─────────────────────────────────────────────────────────────

function parseMeta(html: string): Record<string, string> {
  const head = html.slice(0, 200_000);
  const out: Record<string, string> = {};
  const metaRe = /<meta\s+([^>]+?)\/?>/gi;
  let m: RegExpExecArray | null;
  while ((m = metaRe.exec(head))) {
    const attrs = m[1];
    const name = attr(attrs, "property") ?? attr(attrs, "name");
    const content = attr(attrs, "content");
    if (name && content && !(name in out)) {
      out[name.toLowerCase()] = decode(content);
    }
  }
  const t = head.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (t && !out["title"]) out["title"] = decode(t[1].trim());
  return out;
}

function attr(s: string, name: string): string | null {
  const m = s.match(
    new RegExp(`${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, "i"),
  );
  return m ? (m[2] ?? m[3] ?? m[4] ?? "").trim() : null;
}

function youtubeId(u: URL): string | null {
  const h = u.hostname.replace(/^www\./, "");
  if (h === "youtu.be") return clean(u.pathname.slice(1));
  if (
    h === "youtube.com" || h === "m.youtube.com" || h === "music.youtube.com"
  ) {
    if (u.pathname === "/watch") return clean(u.searchParams.get("v") ?? "");
    const m = u.pathname.match(/^\/(?:live|embed|shorts|v)\/([\w-]{6,})/);
    if (m) return m[1];
  }
  return null;
}

function clean(id: string): string | null {
  const s = id.split(/[?&/]/)[0];
  return /^[\w-]{6,}$/.test(s) ? s : null;
}

function isDirectMedia(u: string): boolean {
  return /\.(mp4|m4v|webm|mov|m3u8)(\?|$)/i.test(u);
}

function abs(v: string | undefined, base: string): string | null {
  if (!v) return null;
  try {
    return new URL(v, base).toString();
  } catch {
    return null;
  }
}

function decode(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&#x27;|&apos;/gi, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .trim();
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
