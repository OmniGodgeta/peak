// ingest-content — mirror public space / gaming / science feeds into Peak.
//
// Image sources (post an image + text):
//   webb    → ESA/Webb image releases   (esawebb.org, CC BY 4.0)
//   hubble  → ESA/Hubble Picture of the Week (esahubble.org, CC BY 4.0)
//   roman   → NASA image library, "Roman Space Telescope" (public domain)
//   launches→ Launch Library 2 upcoming launches (thespacedevs.com)
//
// News sources (post a headline + short excerpt + link, no image):
//   playstation → PlayStation.Blog        → c/playstation
//   xbox        → Xbox Wire               → c/xbox
//   nintendo    → Nintendo Life           → c/nintendo
//   pcgaming    → PC Gamer + RPS          → c/pc-gaming
//   pchardware  → Tom's Hardware + TechPowerUp → c/pc-hardware
//   scinews     → Phys.org + ScienceDaily → c/science-news
//
// Each source posts as its own account into the home feed and mirrors into a
// community channel. Every post links and credits the source. Dedup + a
// per-source throttle live in the content_ingest_seen / content_ingest_run
// tables.
//
// Trigger: pg_cron via pg_net (see docs/HOSTED_BACKEND.md), or by hand:
//   curl -XPOST "$SUPABASE_URL/functions/v1/ingest-content?source=webb&force=1" \
//        -H "Authorization: Bearer $ANON_KEY"
// verify_jwt is off (config.toml): the function trusts no caller input beyond
// the ?source= name and runs entirely on the service role.

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

const NASA_SEARCH = "https://images-api.nasa.gov/search";
const LL2_UPCOMING = "https://ll.thespacedevs.com/2.2.0/launch/upcoming/";

const THROTTLE_MIN = 20;
const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
const BUCKET = "post-media";
const UA = { "User-Agent": "peak-social/ingest (+https://peak.social)" };
// Some outlets 403 a plain UA; present as a generic feed reader for news fetches.
const NEWS_UA = {
  "User-Agent":
    "Mozilla/5.0 (compatible; peak-social/1.0; +https://peak.social) feedreader",
};

interface ImageSource {
  handle: string;
  kind: "esa-rss" | "nasa-images";
  community: string; // slug of the community to mirror into
  channel: string; // channel slug
  max: number;
  url?: string; // esa-rss
  credit?: string; // esa-rss
  query?: string; // nasa-images
  requireKeyword?: RegExp; // nasa-images
}

const IMAGE_SOURCES: Record<string, ImageSource> = {
  webb: {
    handle: "webb",
    kind: "esa-rss",
    url: "https://esawebb.org/images/feed/",
    credit: "Image: ESA/Webb, NASA & CSA — CC BY 4.0",
    community: "astrophotos",
    channel: "general",
    max: 5,
  },
  hubble: {
    handle: "hubble",
    kind: "esa-rss",
    url: "https://esahubble.org/images/potw/feed/",
    credit: "Image: ESA/Hubble & NASA — CC BY 4.0",
    community: "astrophotos",
    channel: "general",
    max: 5,
  },
  roman: {
    handle: "roman",
    kind: "nasa-images",
    query: "Roman Space Telescope",
    requireKeyword: /roman/i,
    community: "astrophotos",
    channel: "general",
    max: 2,
  },
};

interface NewsSource {
  handle: string;
  community: string;
  outlet: string; // shown as "via <outlet>"
  urls: string[];
  max: number;
}

const NEWS_SOURCES: Record<string, NewsSource> = {
  playstation: {
    handle: "playstation",
    community: "playstation",
    outlet: "PlayStation.Blog",
    urls: ["https://blog.playstation.com/feed/"],
    max: 3,
  },
  xbox: {
    handle: "xbox",
    community: "xbox",
    outlet: "Xbox Wire",
    urls: ["https://news.xbox.com/en-us/feed/"],
    max: 3,
  },
  nintendo: {
    handle: "nintendo",
    community: "nintendo",
    outlet: "Nintendo Life",
    urls: ["https://www.nintendolife.com/feeds/latest"],
    max: 3,
  },
  pcgaming: {
    handle: "pcgaming",
    community: "pc-gaming",
    outlet: "PC Gamer / Rock Paper Shotgun",
    urls: [
      "https://www.pcgamer.com/rss/",
      "https://www.rockpapershotgun.com/feed",
    ],
    max: 4,
  },
  pchardware: {
    handle: "pchardware",
    community: "pc-hardware",
    outlet: "Tom's Hardware / TechPowerUp",
    urls: [
      "https://www.tomshardware.com/feeds.xml",
      "https://www.techpowerup.com/rss/news",
    ],
    max: 4,
  },
  scinews: {
    handle: "scinews",
    community: "science-news",
    outlet: "Phys.org / ScienceDaily",
    urls: [
      "https://phys.org/rss-feed/",
      "https://www.sciencedaily.com/rss/all.xml",
    ],
    max: 4,
  },
};

interface Ctx {
  db: SupabaseClient;
  dry: boolean;
}

interface SourceResult {
  source: string;
  skipped?: string;
  added: number;
  seen: number;
  errors: string[];
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return json({ error: "method not allowed" }, 405);
  }

  const url = new URL(req.url);
  const only = url.searchParams.get("source");
  const force = url.searchParams.get("force") === "1";
  const dry = url.searchParams.get("dry") === "1";

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const ctx: Ctx = { db, dry };

  const sources = only ? [only] : [
    ...Object.keys(IMAGE_SOURCES),
    "launches",
    ...Object.keys(NEWS_SOURCES),
  ];
  const results: SourceResult[] = [];

  for (const source of sources) {
    try {
      if (!force && (await throttled(ctx, source))) {
        results.push({
          source,
          skipped: "throttled",
          added: 0,
          seen: 0,
          errors: [],
        });
        continue;
      }
      const res = source === "launches"
        ? await ingestLaunches(ctx)
        : NEWS_SOURCES[source]
        ? await ingestNews(ctx, source)
        : await ingestImages(ctx, source);
      results.push(res);
      if (!dry) await markRun(ctx, source, res);
    } catch (e) {
      results.push({
        source,
        added: 0,
        seen: 0,
        errors: [String(e instanceof Error ? e.message : e)],
      });
    }
  }

  return json({ ok: true, dry, results }, 200);
});

// ── throttle / run bookkeeping ────────────────────────────────────────────

async function throttled(ctx: Ctx, source: string): Promise<boolean> {
  const { data } = await ctx.db
    .from("content_ingest_run")
    .select("last_run_at")
    .eq("source", source)
    .maybeSingle();
  if (!data?.last_run_at) return false;
  const age = Date.now() - new Date(data.last_run_at).getTime();
  return age < THROTTLE_MIN * 60_000;
}

async function markRun(ctx: Ctx, source: string, res: SourceResult) {
  const now = new Date().toISOString();
  await ctx.db.from("content_ingest_run").upsert({
    source,
    last_run_at: now,
    last_ok_at: res.errors.length === 0 ? now : undefined,
    added_last: res.added,
    note: res.errors.length ? res.errors.slice(0, 3).join(" | ") : null,
  });
}

// ── shared lookups ───────────────────────────────────────────────────────

async function author(
  ctx: Ctx,
  handle: string,
): Promise<{ id: string; persona: string }> {
  const { data: prof, error } = await ctx.db
    .from("profile")
    .select("id")
    .eq("handle", handle)
    .single();
  if (error || !prof) throw new Error(`no @${handle} account`);
  const { data: persona } = await ctx.db
    .from("persona")
    .select("id")
    .eq("account_id", prof.id)
    .eq("is_default", true)
    .single();
  if (!persona) throw new Error(`@${handle} has no default persona`);
  return { id: prof.id, persona: persona.id };
}

async function channel(
  ctx: Ctx,
  communitySlug: string,
  channelSlug: string,
): Promise<{ community: string; channel: string } | null> {
  const { data: comm } = await ctx.db
    .from("community")
    .select("id")
    .eq("slug", communitySlug)
    .maybeSingle();
  if (!comm) return null;
  const { data: chan } = await ctx.db
    .from("community_channel")
    .select("id")
    .eq("community_id", comm.id)
    .eq("slug", channelSlug)
    .maybeSingle();
  if (!chan) return null;
  return { community: comm.id, channel: chan.id };
}

async function alreadySeen(ctx: Ctx, source: string): Promise<Set<string>> {
  const { data } = await ctx.db
    .from("content_ingest_seen")
    .select("external_id")
    .eq("source", source)
    .order("seen_at", { ascending: false })
    .limit(500);
  return new Set((data ?? []).map((r) => r.external_id as string));
}

interface Media {
  path: string;
  alt: string;
}

async function insertPost(
  ctx: Ctx,
  row: Record<string, unknown>,
  media?: Media,
): Promise<string> {
  const { data, error } = await ctx.db
    .from("post")
    .insert(row)
    .select("id")
    .single();
  if (error || !data) throw new Error(`post insert: ${error?.message}`);
  if (media) {
    const { error: mErr } = await ctx.db.from("post_media").insert({
      post_id: data.id,
      kind: "image",
      storage_path: media.path,
      alt_text: media.alt,
      sort_order: 0,
    });
    if (mErr) throw new Error(`post_media insert: ${mErr.message}`);
  }
  return data.id;
}

// Post to the home feed and mirror into a community channel. Returns the feed
// post id (recorded as the canonical post for the item).
async function publish(
  ctx: Ctx,
  a: { id: string; persona: string },
  body: string,
  media: Media | undefined,
  mirror: { community: string; channel: string } | null,
): Promise<string> {
  const feed = await insertPost(ctx, {
    author_id: a.id,
    persona_id: a.persona,
    body,
    visibility: "public",
  }, media);
  if (mirror) {
    await insertPost(ctx, {
      author_id: a.id,
      persona_id: a.persona,
      body,
      visibility: "public",
      community_id: mirror.community,
      channel_id: mirror.channel,
    }, media);
  }
  return feed;
}

async function stashImage(
  ctx: Ctx,
  source: string,
  id: string,
  src: string,
  alt: string,
): Promise<Media | null> {
  let res = await fetch(src.replace(/^http:/, "https:"), { headers: UA });
  if (!res.ok && src.includes("/archives/images/screen/")) {
    await res.body?.cancel();
    res = await fetch(
      src.replace("/archives/images/screen/", "/archives/images/news/"),
      {
        headers: UA,
      },
    );
  }
  if (!res.ok) throw new Error(`image ${res.status}`);
  const len = Number(res.headers.get("content-length") ?? "0");
  if (len > MAX_IMAGE_BYTES) {
    await res.body?.cancel();
    throw new Error(`image too large (${len} bytes)`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.byteLength > MAX_IMAGE_BYTES) throw new Error("image too large");
  const ext = /\.png($|\?)/i.test(src) ? "png" : "jpg";
  const path = `ingest/${source}/${slugForPath(id)}.${ext}`;
  const { error } = await ctx.db.storage.from(BUCKET).upload(path, bytes, {
    contentType: ext === "png" ? "image/png" : "image/jpeg",
    upsert: true,
  });
  if (error) throw new Error(`storage: ${error.message}`);
  return { path, alt };
}

// ── image feeds (webb / hubble / roman) ──────────────────────────────────

interface FeedItem {
  externalId: string;
  title: string;
  text: string;
  link: string;
  imageUrl: string | null;
  publishedIso?: string;
}

async function ingestImages(ctx: Ctx, source: string): Promise<SourceResult> {
  const cfg = IMAGE_SOURCES[source];
  if (!cfg) throw new Error(`unknown source ${source}`);
  const out: SourceResult = { source, added: 0, seen: 0, errors: [] };

  const a = await author(ctx, cfg.handle);
  const mirror = await channel(ctx, cfg.community, cfg.channel);
  const seen = await alreadySeen(ctx, source);

  const items = cfg.kind === "esa-rss"
    ? await fetchEsaRss(cfg.url!)
    : await fetchNasaImages(cfg.query!, cfg.requireKeyword);
  out.seen = items.length;

  for (const item of items) {
    if (out.added >= cfg.max) break;
    if (seen.has(item.externalId)) continue;
    try {
      let media: Media | undefined;
      if (item.imageUrl) {
        media = await stashImage(
          ctx,
          source,
          item.externalId,
          item.imageUrl,
          item.title,
        ) ?? undefined;
      }
      const body = [
        item.title,
        clip(item.text, 700),
        cfg.credit,
        item.link,
      ].filter(Boolean).join("\n\n");

      if (ctx.dry) {
        out.added++;
        continue;
      }
      const postId = await publish(ctx, a, body, media, mirror);
      await ctx.db.from("content_ingest_seen").insert({
        source,
        external_id: item.externalId,
        post_id: postId,
        title: item.title,
        url: item.link,
      });
      out.added++;
    } catch (e) {
      out.errors.push(
        `${item.externalId}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }
  }
  return out;
}

async function fetchEsaRss(url: string): Promise<FeedItem[]> {
  const res = await fetch(url, { headers: UA });
  if (!res.ok) throw new Error(`rss ${res.status}`);
  const xml = await res.text();
  const items: FeedItem[] = [];
  for (const block of xml.split(/<item>/).slice(1)) {
    const raw = block.split(/<\/item>/)[0];
    const title = decode(tag(raw, "title"));
    const link = decode(tag(raw, "link")).trim();
    const descRaw = decode(tag(raw, "description"));
    if (!link) continue;
    const img = descRaw.match(
      /https?:\/\/cdn\.(?:esawebb|esahubble|spacetelescope)\.org\/[^\s"'<>]+?\.(?:jpg|jpeg|png)/i,
    );
    // The feed's inline <img> is a ~250px thumbnail; the "screen" rendition
    // (~1280px, a few hundred KB) sits at the same path.
    const imageUrl = img
      ? img[0].replace("/archives/images/news/", "/archives/images/screen/")
      : null;
    items.push({
      externalId: link,
      title: title || "New image",
      text: stripHtml(descRaw),
      link,
      imageUrl,
    });
  }
  return items;
}

interface NasaItem {
  data?: Array<
    {
      nasa_id: string;
      title: string;
      description: string;
      date_created: string;
    }
  >;
}

async function fetchNasaImages(
  query: string,
  keyword?: RegExp,
): Promise<FeedItem[]> {
  const q = new URLSearchParams({ q: query, media_type: "image" });
  const res = await fetch(`${NASA_SEARCH}?${q}`, { headers: UA });
  if (!res.ok) throw new Error(`NASA search ${res.status}`);
  const jsonBody = await res.json();
  const raw = (jsonBody?.collection?.items ?? []) as NasaItem[];
  return raw
    .map((it) => it.data?.[0])
    .filter((d): d is NonNullable<typeof d> => !!d?.nasa_id && !!d.date_created)
    .filter((d) =>
      !keyword || keyword.test(d.title ?? "") ||
      keyword.test(d.description ?? "")
    )
    .sort((x, y) => y.date_created.localeCompare(x.date_created))
    .map((d) => ({
      externalId: d.nasa_id,
      title: d.title?.trim() || "NASA image",
      text: d.description ?? "",
      link: `https://images.nasa.gov/details/${d.nasa_id}`,
      imageUrl:
        `https://images-assets.nasa.gov/image/${d.nasa_id}/${d.nasa_id}~medium.jpg`,
    }));
}

// ── Launch Library 2 ─────────────────────────────────────────────────────

interface Launch {
  id: string;
  name: string;
  net: string;
  image: string | null;
  launch_service_provider?: { name?: string };
  pad?: { name?: string; location?: { name?: string } };
  mission?: { description?: string };
}

async function ingestLaunches(ctx: Ctx): Promise<SourceResult> {
  const out: SourceResult = {
    source: "launches",
    added: 0,
    seen: 0,
    errors: [],
  };
  const a = await author(ctx, "launches");
  const mirror = await channel(ctx, "rockets", "schedule");
  const seen = await alreadySeen(ctx, "launches");

  const q = new URLSearchParams({
    limit: "12",
    hide_recent_previous: "true",
  });
  const res = await fetch(`${LL2_UPCOMING}?${q}`, { headers: UA });
  if (!res.ok) throw new Error(`LL2 ${res.status}`);
  const data = await res.json();
  const launches = (data?.results ?? []) as Launch[];

  const horizon = Date.now() + 21 * 86_400_000;
  const upcoming = launches.filter((l) =>
    l.net && new Date(l.net).getTime() <= horizon
  );
  out.seen = upcoming.length;

  for (const l of upcoming) {
    if (seen.has(l.id)) continue;
    try {
      const provider = l.launch_service_provider?.name ?? "Unknown provider";
      const where = [l.pad?.name, l.pad?.location?.name]
        .filter(Boolean).join(", ");
      const body = [
        `🚀 ${l.name}`,
        [provider, where].filter(Boolean).join(" · "),
        `Launch window opens ${fmtDate(l.net)}`,
        clip(l.mission?.description, 500),
        "via thespacedevs.com",
      ].filter(Boolean).join("\n\n");

      let media: Media | undefined;
      if (l.image) {
        try {
          media = await stashImage(ctx, "launches", l.id, l.image, l.name) ??
            undefined;
        } catch (e) {
          out.errors.push(
            `${l.id} image: ${e instanceof Error ? e.message : e}`,
          );
        }
      }

      if (ctx.dry) {
        out.added++;
        continue;
      }
      const postId = await publish(ctx, a, body, media, mirror);
      await ctx.db.from("content_ingest_seen").insert({
        source: "launches",
        external_id: l.id,
        post_id: postId,
        title: l.name,
        url: `https://thespacedevs.com/launch/${l.id}`,
      });
      out.added++;
    } catch (e) {
      out.errors.push(`${l.id}: ${e instanceof Error ? e.message : String(e)}`);
    }
  }
  return out;
}

// ── news feeds (playstation / xbox / nintendo / pcgaming / pchardware / scinews)

async function ingestNews(ctx: Ctx, source: string): Promise<SourceResult> {
  const cfg = NEWS_SOURCES[source];
  if (!cfg) throw new Error(`unknown source ${source}`);
  const out: SourceResult = { source, added: 0, seen: 0, errors: [] };

  const a = await author(ctx, cfg.handle);
  const mirror = await channel(ctx, cfg.community, "general");
  const seen = await alreadySeen(ctx, source);

  const items: FeedItem[] = [];
  const ids = new Set<string>();
  for (const url of cfg.urls) {
    try {
      for (const it of await fetchNewsRss(url)) {
        if (ids.has(it.externalId)) continue;
        ids.add(it.externalId);
        items.push(it);
      }
    } catch (e) {
      out.errors.push(`${url}: ${e instanceof Error ? e.message : e}`);
    }
  }
  items.sort((x, y) =>
    (y.publishedIso ?? "").localeCompare(x.publishedIso ?? "")
  );
  out.seen = items.length;

  for (const item of items) {
    if (out.added >= cfg.max) break;
    if (seen.has(item.externalId)) continue;
    try {
      const body = [
        item.title,
        clip(item.text, 280),
        `via ${cfg.outlet} · ${item.link}`,
      ].filter(Boolean).join("\n\n");

      if (ctx.dry) {
        out.added++;
        continue;
      }
      const postId = await publish(ctx, a, body, undefined, mirror);
      await ctx.db.from("content_ingest_seen").insert({
        source,
        external_id: item.externalId,
        post_id: postId,
        title: item.title,
        url: item.link,
      });
      out.added++;
    } catch (e) {
      out.errors.push(
        `${item.externalId}: ${e instanceof Error ? e.message : String(e)}`,
      );
    }
  }
  return out;
}

async function fetchNewsRss(url: string): Promise<FeedItem[]> {
  const res = await fetch(url, { headers: NEWS_UA, redirect: "follow" });
  if (!res.ok) throw new Error(`rss ${res.status}`);
  const xml = await res.text();
  const items: FeedItem[] = [];
  for (const block of xml.split(/<item>/i).slice(1)) {
    const raw = block.split(/<\/item>/i)[0];
    const title = decode(tag(raw, "title")).trim();
    const link = decode(tag(raw, "link")).trim();
    const guid = decode(tag(raw, "guid")).trim();
    // Prefer the article link — some feeds (e.g. Nintendo Life) repeat the same
    // useless <guid> on every item.
    const id = (link || guid).split("#")[0];
    if (!id || !title) continue;
    const descRaw = tag(raw, "description") || tag(raw, "summary");
    const when = tag(raw, "pubDate") || tag(raw, "dc:date") ||
      tag(raw, "published");
    let publishedIso: string | undefined;
    if (when) {
      const t = new Date(when.trim());
      if (!Number.isNaN(t.getTime())) publishedIso = t.toISOString();
    }
    const text = stripHtml(decode(descRaw))
      // WordPress feeds tack this onto every excerpt.
      .replace(/\s*The post .+? appeared first on .+?\.?\s*$/i, "")
      .replace(/\s*Continue reading[\s\S]*$/i, "")
      .replace(/\s*Read more[\s\S]*$/i, "");
    items.push({
      externalId: id,
      title,
      text,
      link: link || guid,
      imageUrl: null,
      publishedIso,
    });
  }
  return items;
}

// ── helpers ──────────────────────────────────────────────────────────────

function tag(xml: string, name: string): string {
  const m = xml.match(
    new RegExp(`<${name}[^>]*>([\\s\\S]*?)<\\/${name}>`, "i"),
  );
  if (!m) return "";
  return m[1].replace(/^<!\[CDATA\[/, "").replace(/\]\]>$/, "");
}

function decode(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&#x27;/gi, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#8217;/g, "’")
    .replace(/&#8216;/g, "‘")
    .replace(/&#8211;/g, "–")
    .replace(/&#8212;/g, "—")
    .replace(/&amp;/g, "&");
}

function stripHtml(s: string): string {
  return s
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function slugForPath(id: string): string {
  const s = id.replace(/^https?:\/\//, "").replace(/[^a-zA-Z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return s.length <= 80 ? s : s.slice(-80);
}

function clip(s: string | undefined | null, n: number): string {
  const t = (s ?? "").trim();
  if (t.length <= n) return t;
  return `${t.slice(0, n - 1).trimEnd()}…`;
}

function fmtDate(iso: string): string {
  try {
    return new Date(iso).toLocaleString("en-US", {
      dateStyle: "full",
      timeStyle: "short",
      timeZone: "UTC",
    }) + " UTC";
  } catch {
    return iso;
  }
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
