// publish — create a post with its circle audience + resolved mentions.
//
// Why an Edge Function and not a plain insert: a "circles" post must land its
// `post_audience` rows in the same transaction as the post, mentions must be
// resolved server-side (the client must not be trusted to list who it notified),
// and we want one place to enforce the alt-text / rate-limit / teen rules.
//
// Auth: the caller's JWT is verified by the Edge runtime; we read their id from
// it and never from the payload.

import { createClient } from "jsr:@supabase/supabase-js@2";

interface PublishRequest {
  body: string;
  personaId: string;
  visibility?: "circles" | "public" | "mentioned" | "followers";
  circleIds?: string[];
  replyTo?: string | null;
  quoteOf?: string | null;
  contentWarning?: string | null;
  isSensitive?: boolean;
  lang?: string | null;
  media?: Array<{
    kind: "image" | "video" | "audio";
    storagePath: string;
    altText?: string | null;
    width?: number;
    height?: number;
    durationMs?: number;
  }>;
}

const MENTION_RE = /(?:^|\s)@([a-z0-9_]{2,30})\b/g;

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: userData, error: userErr } = await db.auth.getUser();
  if (userErr || !userData.user) return json({ error: "unauthorized" }, 401);
  const uid = userData.user.id;

  let input: PublishRequest;
  try {
    input = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }

  if (!input.body?.trim() && !(input.media?.length)) {
    return json({ error: "empty post" }, 422);
  }
  if (input.body && input.body.length > 5000) {
    return json({ error: "body too long" }, 422);
  }
  const visibility = input.visibility ?? "circles";
  if (visibility === "circles" && !(input.circleIds?.length)) {
    return json({ error: "a circles post needs at least one circle" }, 422);
  }
  // Deliberate friction, not a block: images without alt text are allowed only
  // if the client explicitly passed altText === "" (user tapped "post anyway").
  for (const m of input.media ?? []) {
    if (m.kind === "image" && m.altText === undefined) {
      return json({ error: 'each image needs altText ("" to skip)' }, 422);
    }
  }

  // 1. the post
  const { data: post, error: postErr } = await db
    .from("post")
    .insert({
      author_id: uid,
      persona_id: input.personaId,
      body: input.body ?? "",
      lang: input.lang ?? null,
      visibility,
      reply_to: input.replyTo ?? null,
      root_id: input.replyTo ? (input.replyTo) : null,
      quote_of: input.quoteOf ?? null,
      content_warning: input.contentWarning ?? null,
      is_sensitive: input.isSensitive ?? false,
    })
    .select()
    .single();
  if (postErr) return json({ error: postErr.message }, 400);

  // 2. audience
  if (visibility === "circles") {
    const rows = input.circleIds!.map((cid) => ({
      post_id: post.id,
      circle_id: cid,
    }));
    const { error } = await db.from("post_audience").insert(rows);
    if (error) {
      await db.from("post").delete().eq("id", post.id);
      return json({ error: error.message }, 400);
    }
  }

  // 3. media
  if (input.media?.length) {
    const rows = input.media.map((m, i) => ({
      post_id: post.id,
      kind: m.kind,
      storage_path: m.storagePath,
      alt_text: m.altText ?? null,
      width: m.width ?? null,
      height: m.height ?? null,
      duration_ms: m.durationMs ?? null,
      sort_order: i,
    }));
    await db.from("post_media").insert(rows);
  }

  // 4. mentions — resolved here, never trusted from the client
  const handles = [...(input.body ?? "").matchAll(MENTION_RE)].map((m) =>
    m[1].toLowerCase()
  );
  if (handles.length) {
    const { data: mentioned } = await db
      .from("profile")
      .select("id")
      .in("handle", [...new Set(handles)]);
    if (mentioned?.length) {
      await db.from("mention").insert(
        mentioned.map((p) => ({ post_id: post.id, mentioned_id: p.id })),
      );
    }
  }

  // TODO(phase 5): enqueue fanout for the ranked feed index.
  // TODO(phase 1): enqueue push notifications for mentions + replies.

  return json({ post }, 201);
});

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
