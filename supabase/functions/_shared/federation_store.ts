// Database + network helpers shared by the federation and
// federation-deliver functions. Service-role client only.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { Fed, idOf } from "./activitypub.ts";
import { generateActorKeys } from "./httpsig.ts";
import { assertPublicHost } from "./public_host.ts";

export const service = (): SupabaseClient =>
  createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

/**
 * Federation is live only when the flag is on AND a public base URL is set.
 * Returns null otherwise — callers answer 404 so nothing is advertised.
 */
export async function fedConfig(db: SupabaseClient): Promise<Fed | null> {
  const base = Deno.env.get("FEDERATION_BASE_URL");
  if (!base || !/^https:\/\//.test(base)) return null;
  const { data } = await db.from("system_config").select("value")
    .eq("key", "federation_enabled").maybeSingle();
  return data?.value === "true" ? new Fed(base) : null;
}

export interface LocalProfile {
  id: string;
  handle: string;
  display_name: string | null;
  bio: string | null;
  avatar_path: string | null;
  account_kind: string;
  federated: boolean;
  also_known_as: string[];
  moved_to: string | null;
  created_at: string;
}

/** A local account that may appear on other servers, or null. */
export async function federatedProfile(
  db: SupabaseClient,
  by: { handle?: string; id?: string },
): Promise<LocalProfile | null> {
  let q = db.from("profile").select(
    "id, handle, display_name, bio, avatar_path, account_kind, federated, also_known_as, moved_to, created_at",
  );
  q = by.id ? q.eq("id", by.id) : q.eq("handle", by.handle ?? "");
  const { data } = await q.maybeSingle();
  const p = data as LocalProfile | null;
  return p && p.federated && p.account_kind !== "teen" ? p : null;
}

export async function ensureKey(
  db: SupabaseClient,
  profileId: string,
): Promise<{ publicPem: string; privatePem: string }> {
  const { data } = await db.from("actor_key")
    .select("public_key_pem, private_key_pem").eq("profile_id", profileId)
    .maybeSingle();
  if (data) {
    return { publicPem: data.public_key_pem, privatePem: data.private_key_pem };
  }
  const k = await generateActorKeys();
  // Two requests racing to create a key: keep whichever landed first.
  await db.from("actor_key").upsert(
    {
      profile_id: profileId,
      public_key_pem: k.publicPem,
      private_key_pem: k.privatePem,
    },
    { onConflict: "profile_id", ignoreDuplicates: true },
  );
  const { data: row } = await db.from("actor_key")
    .select("public_key_pem, private_key_pem").eq("profile_id", profileId)
    .single();
  return { publicPem: row!.public_key_pem, privatePem: row!.private_key_pem };
}

export async function isBlocked(
  db: SupabaseClient,
  domain: string,
): Promise<boolean> {
  const { data } = await db.from("federation_instance_policy").select("domain")
    .eq("domain", domain.toLowerCase()).maybeSingle();
  return !!data;
}

const MAX_DOC = 1_000_000;

/** GET an ActivityPub/JSON document from a public https URL. */
export async function fetchJson(
  url: string,
  accept = "application/activity+json",
): Promise<unknown> {
  const u = new URL(url);
  if (u.protocol !== "https:") throw new Error("https only");
  await assertPublicHost(u);
  const res = await fetch(u, {
    headers: {
      accept:
        `${accept}, application/ld+json; profile="https://www.w3.org/ns/activitystreams"`,
      "user-agent": "Peak (+ActivityPub)",
    },
    redirect: "manual",
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`fetch ${u.host} said ${res.status}`);
  }
  const text = await res.text();
  if (text.length > MAX_DOC) throw new Error("document too large");
  return JSON.parse(text);
}

export interface RemoteActorRow {
  id: string;
  uri: string;
  domain: string;
  inbox: string;
  shared_inbox: string | null;
  preferred_username: string | null;
  display_name: string | null;
  icon_url: string | null;
  public_key_id: string | null;
  public_key_pem: string | null;
  also_known_as: string[];
  moved_to: string | null;
  fetched_at: string;
}

/**
 * The remote actor at [uri], from cache unless [refresh] or older than a
 * day. The fetched document must say it IS that uri (no impersonation via
 * redirects or mismatched ids).
 */
export async function remoteActor(
  db: SupabaseClient,
  uri: string,
  refresh = false,
): Promise<RemoteActorRow> {
  if (!refresh) {
    const { data } = await db.from("remote_actor").select("*").eq("uri", uri)
      .maybeSingle();
    if (data && Date.now() - Date.parse(data.fetched_at) < 86400_000) {
      return data as RemoteActorRow;
    }
  }
  const doc = await fetchJson(uri) as Record<string, unknown>;
  if (doc.id !== uri) throw new Error("actor id mismatch");
  const inbox = typeof doc.inbox === "string" ? doc.inbox : null;
  if (!inbox || !inbox.startsWith("https://")) {
    throw new Error("actor has no https inbox");
  }
  const pk = doc.publicKey as Record<string, unknown> | undefined;
  const endpoints = doc.endpoints as Record<string, unknown> | undefined;
  const shared = typeof endpoints?.sharedInbox === "string" &&
      endpoints.sharedInbox.startsWith("https://")
    ? endpoints.sharedInbox
    : null;
  const aka = Array.isArray(doc.alsoKnownAs)
    ? doc.alsoKnownAs.filter((x): x is string => typeof x === "string")
    : [];
  const row = {
    uri,
    domain: new URL(uri).host.toLowerCase(),
    inbox,
    shared_inbox: shared,
    preferred_username: typeof doc.preferredUsername === "string"
      ? doc.preferredUsername.slice(0, 100)
      : null,
    display_name: typeof doc.name === "string" ? doc.name.slice(0, 200) : null,
    icon_url:
      typeof idOf((doc.icon as { url?: unknown })?.url ?? null) === "string"
        ? idOf((doc.icon as { url?: unknown }).url)
        : null,
    public_key_id: typeof pk?.id === "string" ? pk.id : null,
    public_key_pem: typeof pk?.publicKeyPem === "string"
      ? pk.publicKeyPem
      : null,
    also_known_as: aka,
    moved_to: typeof doc.movedTo === "string" ? doc.movedTo : null,
    fetched_at: new Date().toISOString(),
  };
  const { data, error } = await db.from("remote_actor")
    .upsert(row, { onConflict: "uri" }).select("*").single();
  if (error) throw error;
  return data as RemoteActorRow;
}

/** @user@server → actor URI via WebFinger. */
export async function resolveHandle(handle: string): Promise<string> {
  const m = handle.trim().replace(/^@/, "").match(
    /^([^@\s]+)@([a-z0-9.-]+\.[a-z]{2,})$/i,
  );
  if (!m) throw new Error("expected @user@server");
  const jrd = await fetchJson(
    `https://${m[2]}/.well-known/webfinger?resource=${
      encodeURIComponent(`acct:${m[1]}@${m[2]}`)
    }`,
    "application/jrd+json",
  ) as { links?: { rel?: string; type?: string; href?: string }[] };
  const self = jrd.links?.find((l) =>
    l.rel === "self" && (l.type ?? "").includes("activity+json") &&
    l.href?.startsWith("https://")
  );
  if (!self?.href) throw new Error("no ActivityPub actor for that address");
  return self.href;
}

export function publicStorageUrl(bucket: string, path: string): string {
  if (/^https?:\/\//.test(path)) return path;
  return `${
    Deno.env.get("SUPABASE_URL")
  }/storage/v1/object/public/${bucket}/${path}`;
}

/** Public URL for a post-media storage value (bucket path or full URL). */
export const mediaUrl = (storagePath: string) =>
  publicStorageUrl("post-media", storagePath);
