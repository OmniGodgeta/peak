// federation — Peak's ActivityPub server (Phase 7).
//
// Serves, when federation is on (system_config flag + FEDERATION_BASE_URL):
//   GET  /.well-known/webfinger?resource=acct:handle@domain
//   GET  /.well-known/nodeinfo, /nodeinfo/2.0
//   GET  /users/:handle            Person (only people who opted in, no teens)
//   GET  /users/:handle/outbox     recent public posts
//   GET  /users/:handle/followers  count only
//   GET  /posts/:id                a public post as a Note
//   POST /inbox, /users/:handle/inbox   signed activities (see handle())
//   POST /api/resolve|follow|unfollow|move   signed-in Peak users (JWT)
// Otherwise everything is 404, so nothing is advertised.
//
// Behind a reverse proxy mapping https://<domain>/… to this function, the
// public path is whatever follows "/federation"; signatures are checked
// against FEDERATION_BASE_URL's host and that public path.
//
// verify_jwt is off for this function (config.toml): remote servers don't
// carry Supabase JWTs. /api/* checks the caller's JWT itself.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import {
  actorDoc,
  create,
  type Fed,
  htmlToText,
  idOf,
  nodeinfo,
  noteDoc,
  webfinger,
} from "../_shared/activitypub.ts";
import { parseSignature, verifyRequest } from "../_shared/httpsig.ts";
import {
  ensureKey,
  fedConfig,
  federatedProfile,
  isBlocked,
  type LocalProfile,
  mediaUrl,
  publicStorageUrl,
  remoteActor,
  type RemoteActorRow,
  resolveHandle,
  service,
} from "../_shared/federation_store.ts";

const AP = "application/activity+json";
const MAX_BODY = 256 * 1024;

const json = (v: unknown, status = 200, type = "application/json") =>
  new Response(JSON.stringify(v), {
    status,
    headers: { "content-type": type },
  });
const notFound = () => json({ error: "not found" }, 404);

Deno.serve(async (req) => {
  const db = service();
  const fed = await fedConfig(db);
  if (!fed) return notFound();

  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/federation(?=\/|$)/, "") || "/";

  try {
    if (req.method === "GET") return await get(db, fed, path, url);
    if (req.method === "POST") {
      if (path.startsWith("/api/")) return await api(req, db, fed, path);
      if (path === "/inbox" || /^\/users\/[^/]+\/inbox$/.test(path)) {
        return await inbox(req, db, fed, path);
      }
    }
    return notFound();
  } catch (e) {
    console.warn(
      `federation ${req.method} ${path}: ${e instanceof Error ? e.message : e}`,
    );
    return json({ error: "bad request" }, 400);
  }
});

// ── reads ────────────────────────────────────────────────────────────────

async function actorFor(db: SupabaseClient, fed: Fed, p: LocalProfile) {
  const key = await ensureKey(db, p.id);
  return actorDoc(fed, {
    handle: p.handle,
    displayName: p.display_name,
    bio: p.bio,
    avatarUrl: p.avatar_path
      ? publicStorageUrl("avatars", p.avatar_path)
      : null,
    publicKeyPem: key.publicPem,
    alsoKnownAs: p.also_known_as ?? [],
    movedTo: p.moved_to,
    createdAt: p.created_at,
  });
}

async function localNote(db: SupabaseClient, postId: string) {
  const { data: p } = await db.from("post")
    .select(
      "id, author_id, body, title, content_warning, created_at, reply_to, visibility, deleted_at, community_id",
    )
    .eq("id", postId).maybeSingle();
  if (!p || p.visibility !== "public" || p.deleted_at || p.community_id) {
    return null;
  }
  const author = await federatedProfile(db, { id: p.author_id });
  if (!author) return null;
  const { data: media } = await db.from("post_media")
    .select("kind, storage_path, alt_text").eq("post_id", p.id).order(
      "sort_order",
    );
  return {
    author,
    note: {
      id: p.id,
      authorHandle: author.handle,
      body: p.body ?? "",
      title: p.title,
      contentWarning: p.content_warning,
      createdAt: p.created_at,
      replyToLocalId: p.reply_to,
      replyToUri: null,
      attachments: (media ?? []).map((m) => ({
        url: mediaUrl(m.storage_path),
        mediaType: m.kind === "video"
          ? "video/mp4"
          : m.kind === "audio"
          ? "audio/mp4"
          : "image/jpeg",
        alt: m.alt_text,
      })),
    },
  };
}

async function get(
  db: SupabaseClient,
  fed: Fed,
  path: string,
  url: URL,
): Promise<Response> {
  if (path === "/.well-known/webfinger") {
    const res = url.searchParams.get("resource") ?? "";
    const m = res.match(/^acct:([^@]+)@(.+)$/i);
    const handle = m && m[2].toLowerCase() === fed.domain.toLowerCase()
      ? m[1]
      : fed.localHandle(res);
    const p = handle ? await federatedProfile(db, { handle }) : null;
    return p
      ? json(webfinger(fed, p.handle), 200, "application/jrd+json")
      : notFound();
  }
  if (path === "/.well-known/nodeinfo") {
    return json({
      links: [{
        rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
        href: `${fed.base}/nodeinfo/2.0`,
      }],
    });
  }
  if (path === "/nodeinfo/2.0") {
    const { count: users } = await db.from("profile").select("id", {
      count: "exact",
      head: true,
    })
      .eq("federated", true);
    return json(nodeinfo(users ?? 0, 0, "1"));
  }
  let m = path.match(/^\/users\/([^/]+)$/);
  if (m) {
    const p = await federatedProfile(db, { handle: decodeURIComponent(m[1]) });
    return p ? json(await actorFor(db, fed, p), 200, AP) : notFound();
  }
  m = path.match(/^\/users\/([^/]+)\/followers$/);
  if (m) {
    const p = await federatedProfile(db, { handle: decodeURIComponent(m[1]) });
    if (!p) return notFound();
    const { count } = await db.from("remote_follower").select(
      "remote_actor_id",
      { count: "exact", head: true },
    )
      .eq("local_profile_id", p.id);
    return json(
      {
        "@context": "https://www.w3.org/ns/activitystreams",
        id: `${fed.actor(p.handle)}/followers`,
        type: "OrderedCollection",
        totalItems: count ?? 0,
      },
      200,
      AP,
    );
  }
  m = path.match(/^\/users\/([^/]+)\/outbox$/);
  if (m) {
    const p = await federatedProfile(db, { handle: decodeURIComponent(m[1]) });
    if (!p) return notFound();
    const { data: posts } = await db.from("post").select("id")
      .eq("author_id", p.id).eq("visibility", "public").is("deleted_at", null)
      .is("community_id", null)
      .order("created_at", { ascending: false }).limit(20);
    const items = [];
    for (const row of posts ?? []) {
      const n = await localNote(db, row.id);
      if (n) items.push(create(fed, n.note));
    }
    return json(
      {
        "@context": "https://www.w3.org/ns/activitystreams",
        id: `${fed.actor(p.handle)}/outbox`,
        type: "OrderedCollection",
        totalItems: items.length,
        orderedItems: items,
      },
      200,
      AP,
    );
  }
  m = path.match(/^\/posts\/([0-9a-f-]{36})$/);
  if (m) {
    const n = await localNote(db, m[1]);
    return n
      ? json(
        {
          "@context": "https://www.w3.org/ns/activitystreams",
          ...noteDoc(fed, n.note),
        },
        200,
        AP,
      )
      : notFound();
  }
  return notFound();
}

// ── inbox ────────────────────────────────────────────────────────────────

type Activity = Record<string, unknown>;

async function inbox(
  req: Request,
  db: SupabaseClient,
  fed: Fed,
  path: string,
): Promise<Response> {
  const body = await req.text();
  if (body.length > MAX_BODY) return json({ error: "too large" }, 413);
  const sigHeader = req.headers.get("signature");
  if (!sigHeader) return json({ error: "unsigned" }, 401);
  const sig = parseSignature(sigHeader);
  const keyOwner = sig.keyId.replace(/#.*$/, "");
  const keyDomain = new URL(keyOwner).host.toLowerCase();
  // Blocked servers get a quiet 202: no reason to tell them.
  if (await isBlocked(db, keyDomain)) return json({}, 202);

  // Verify against the public URL the sender signed, not the proxied one.
  const publicUrl = fed.base + path;
  const headers = new Headers(req.headers);
  headers.set("host", fed.domain);
  const signed = { method: "POST", url: publicUrl, headers };

  let actor = await remoteActor(db, keyOwner);
  try {
    await verifyRequest(signed, body, sig, actor.public_key_pem ?? "");
  } catch {
    // They may have rotated keys: refetch once and retry.
    actor = await remoteActor(db, keyOwner, true);
    await verifyRequest(signed, body, sig, actor.public_key_pem ?? "");
  }

  const activity = JSON.parse(body) as Activity;
  // The signer must be the actor the activity claims to be from.
  if (idOf(activity.actor) !== actor.uri) {
    return json({ error: "actor mismatch" }, 401);
  }

  const activityId = typeof activity.id === "string" ? activity.id : null;
  if (activityId) {
    const { error } = await db.from("federation_inbox_seen").insert({
      activity_id: activityId,
    });
    if (error) return json({}, 202); // already processed
  }
  await handle(db, fed, actor, activity);
  return json({}, 202);
}

async function handle(
  db: SupabaseClient,
  fed: Fed,
  actor: RemoteActorRow,
  a: Activity,
) {
  const type = a.type;
  const object = a.object as Activity | string | undefined;
  const objectId = idOf(object ?? null);

  switch (type) {
    case "Follow": {
      const handle = fed.localHandle(objectId);
      const local = handle ? await federatedProfile(db, { handle }) : null;
      if (!local) return;
      await db.from("remote_follower").upsert({
        local_profile_id: local.id,
        remote_actor_id: actor.id,
        follow_uri: typeof a.id === "string" ? a.id : null,
      }, { onConflict: "local_profile_id,remote_actor_id" });
      await db.from("federation_job").insert({
        kind: "accept",
        local_profile_id: local.id,
        object_id: typeof a.id === "string" ? a.id : null,
        payload: { follow: a },
        target_inbox: actor.inbox,
      });
      return;
    }
    case "Undo": {
      const inner = typeof object === "object" ? object : null;
      if (!inner) return;
      if (inner.type === "Follow") {
        const handle = fed.localHandle(idOf(inner.object ?? null));
        const local = handle ? await federatedProfile(db, { handle }) : null;
        if (local) {
          await db.from("remote_follower").delete()
            .eq("local_profile_id", local.id).eq("remote_actor_id", actor.id);
        }
      } else if (inner.type === "Like" && typeof inner.id === "string") {
        await db.from("remote_reaction").delete()
          .eq("activity_uri", inner.id).eq("remote_actor_id", actor.id);
      }
      return;
    }
    case "Like": {
      const postId = fed.localPostId(objectId);
      if (!postId || typeof a.id !== "string") return;
      const { data: p } = await db.from("post").select(
        "id, visibility, deleted_at",
      )
        .eq("id", postId).maybeSingle();
      if (!p || p.visibility !== "public" || p.deleted_at) return;
      await db.from("remote_reaction").upsert(
        { post_id: postId, remote_actor_id: actor.id, activity_uri: a.id },
        { onConflict: "post_id,remote_actor_id" },
      );
      return;
    }
    case "Create": {
      if (!object || typeof object !== "object" || object.type !== "Note") {
        return;
      }
      const uri = idOf(object);
      if (!uri || new URL(uri).host.toLowerCase() !== actor.domain) return; // their own notes only
      if (idOf(object.attributedTo ?? null) !== actor.uri) return;
      const replyUri = idOf(object.inReplyTo ?? null);
      const replyTo = fed.localPostId(replyUri);
      let keep = false;
      if (replyTo) {
        const { data: p } = await db.from("post").select(
          "visibility, deleted_at",
        )
          .eq("id", replyTo).maybeSingle();
        keep = !!p && p.visibility === "public" && !p.deleted_at;
      }
      if (!keep) {
        const { count } = await db.from("remote_following").select(
          "remote_actor_id",
          { count: "exact", head: true },
        )
          .eq("remote_actor_id", actor.id).eq("state", "accepted");
        keep = (count ?? 0) > 0;
      }
      if (!keep) return; // not addressed to anything here
      const published = typeof object.published === "string" &&
          Number.isFinite(Date.parse(object.published))
        ? object.published
        : new Date().toISOString();
      await db.from("remote_post").upsert({
        uri,
        remote_actor_id: actor.id,
        body: htmlToText(
          typeof object.content === "string" ? object.content : "",
        ),
        content_warning: typeof object.summary === "string" && object.summary
          ? htmlToText(object.summary, 200)
          : null,
        url: typeof object.url === "string" && object.url.startsWith("https://")
          ? object.url
          : null,
        in_reply_to_post: replyTo && keep ? replyTo : null,
        in_reply_to_uri: replyUri,
        published_at: published,
      }, { onConflict: "uri" });
      return;
    }
    case "Delete": {
      if (objectId === actor.uri) {
        await db.from("remote_actor").delete().eq("id", actor.id); // account gone
      } else if (objectId) {
        await db.from("remote_post").delete().eq("uri", objectId).eq(
          "remote_actor_id",
          actor.id,
        );
      }
      return;
    }
    case "Accept": {
      const inner = typeof object === "object" ? object : null;
      const followUri = idOf(inner ?? objectId);
      const m = followUri?.match(/\/activities\/follow\/([0-9a-f-]{36})$/);
      if (!m || !followUri?.startsWith(fed.base)) return;
      await db.from("remote_following").update({ state: "accepted" })
        .eq("follow_id", m[1]).eq("remote_actor_id", actor.id);
      return;
    }
    case "Reject": {
      const followUri = idOf(
        typeof object === "object" ? object : objectId ?? null,
      );
      const m = followUri?.match(/\/activities\/follow\/([0-9a-f-]{36})$/);
      if (!m) return;
      await db.from("remote_following").delete().eq("follow_id", m[1]).eq(
        "remote_actor_id",
        actor.id,
      );
      return;
    }
    case "Update": {
      if (objectId === actor.uri) await remoteActor(db, actor.uri, true);
      return;
    }
    case "Move": {
      await handleMove(db, fed, actor, idOf(a.target ?? null));
      return;
    }
  }
}

/**
 * A remote account moved to [target]. Only honoured when the target lists
 * the old account in alsoKnownAs. Local people following the old account
 * follow the new one instead: a local follow if it moved here, otherwise a
 * new remote follow.
 */
async function handleMove(
  db: SupabaseClient,
  fed: Fed,
  from: RemoteActorRow,
  target: string | null,
) {
  if (!target) return;
  const localHandle = fed.localHandle(target);
  let aliases: string[];
  let local: LocalProfile | null = null;
  let remoteTarget: RemoteActorRow | null = null;
  if (localHandle) {
    local = await federatedProfile(db, { handle: localHandle });
    aliases = local?.also_known_as ?? [];
  } else {
    remoteTarget = await remoteActor(db, target, true);
    aliases = remoteTarget.also_known_as;
  }
  if (!aliases.includes(from.uri)) return;
  await db.from("remote_actor").update({ moved_to: target }).eq("id", from.id);

  const { data: followers } = await db.from("remote_following")
    .select("local_profile_id").eq("remote_actor_id", from.id);
  for (const f of followers ?? []) {
    if (local) {
      await db.from("follow").upsert(
        { follower_id: f.local_profile_id, followee_id: local.id },
        { onConflict: "follower_id,followee_id", ignoreDuplicates: true },
      );
    } else if (remoteTarget) {
      const { data: row } = await db.from("remote_following").upsert(
        {
          local_profile_id: f.local_profile_id,
          remote_actor_id: remoteTarget.id,
          state: "pending",
        },
        { onConflict: "local_profile_id,remote_actor_id" },
      ).select("follow_id").single();
      await db.from("federation_job").insert({
        kind: "follow",
        local_profile_id: f.local_profile_id,
        object_id: row?.follow_id,
        payload: { target: remoteTarget.uri },
        target_inbox: remoteTarget.inbox,
      });
    }
  }
  await db.from("remote_following").delete().eq("remote_actor_id", from.id);
}

// ── signed-in API (Peak's own app) ───────────────────────────────────────

async function api(
  req: Request,
  db: SupabaseClient,
  fed: Fed,
  path: string,
): Promise<Response> {
  const auth = req.headers.get("authorization") ?? "";
  const asUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      auth: { persistSession: false },
      global: { headers: { Authorization: auth } },
    },
  );
  const { data: u } = await asUser.auth.getUser();
  if (!u?.user) return json({ error: "sign in first" }, 401);
  const me = await federatedProfile(db, { id: u.user.id });
  if (!me) {
    return json({ error: "turn on federation for your account first" }, 403);
  }
  const body = await req.json().catch(() => ({})) as Record<string, unknown>;

  if (path === "/api/resolve" || path === "/api/follow") {
    const uri = await resolveHandle(String(body.handle ?? ""));
    if (fed.localHandle(uri)) {
      return json({ error: "that's an account on Peak" }, 400);
    }
    const actor = await remoteActor(db, uri);
    if (await isBlocked(db, actor.domain)) {
      return json({ error: "that server is blocked here" }, 403);
    }
    if (path === "/api/resolve") {
      return json({
        uri: actor.uri,
        handle: `${actor.preferred_username}@${actor.domain}`,
        name: actor.display_name,
        icon: actor.icon_url,
      });
    }
    const { data: row, error } = await db.from("remote_following").upsert(
      { local_profile_id: me.id, remote_actor_id: actor.id, state: "pending" },
      { onConflict: "local_profile_id,remote_actor_id" },
    ).select("follow_id").single();
    if (error) throw error;
    await db.from("federation_job").insert({
      kind: "follow",
      local_profile_id: me.id,
      object_id: row.follow_id,
      payload: { target: actor.uri },
      target_inbox: actor.inbox,
    });
    return json({ ok: true, state: "pending" });
  }

  if (path === "/api/unfollow") {
    const { data: actor } = await db.from("remote_actor").select(
      "id, uri, inbox",
    )
      .eq("id", String(body.actor_id ?? "")).maybeSingle();
    if (!actor) return json({ error: "not found" }, 404);
    const { data: row } = await db.from("remote_following").delete()
      .eq("local_profile_id", me.id).eq("remote_actor_id", actor.id).select(
        "follow_id",
      ).maybeSingle();
    if (row) {
      await db.from("federation_job").insert({
        kind: "unfollow",
        local_profile_id: me.id,
        object_id: row.follow_id,
        payload: { target: actor.uri },
        target_inbox: actor.inbox,
      });
    }
    return json({ ok: true });
  }

  if (path === "/api/move") {
    // Moving OUT: the new account must already list this one as an alias.
    const target = await resolveHandle(String(body.handle ?? ""));
    const actor = await remoteActor(db, target, true);
    if (!actor.also_known_as.includes(fed.actor(me.handle))) {
      return json({
        error: `add ${
          fed.actor(me.handle)
        } as an alias ("also known as") on the new account first`,
      }, 400);
    }
    await db.from("profile").update({ moved_to: actor.uri }).eq("id", me.id);
    await db.from("federation_job").insert({
      kind: "move",
      local_profile_id: me.id,
      object_id: crypto.randomUUID(),
      payload: { target: actor.uri },
    });
    return json({ ok: true, moved_to: actor.uri });
  }

  return notFound();
}
