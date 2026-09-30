// push-dispatch — delivers Peak's push notifications over Web Push to
// UnifiedPush distributors (ntfy, NextPush, ...). No Google, no Firebase.
//
//   POST {}                                  pg_cron, every minute: send
//                                            whatever push_queue has due,
//                                            one bundled push per person.
//   POST {"ring":{"room":..,"conversation":..}}  with the caller's JWT: ring
//                                            the other people in a DM call.
//
// Every payload is encrypted to the device (RFC 8291); the distributor sees
// only ciphertext. Endpoints are user-supplied, so private/internal hosts are
// refused (SSRF), redirects aren't followed, and dead endpoints are dropped.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { encryptWebPush } from "../_shared/webpush.ts";
import { assertPublicHost } from "../_shared/public_host.ts";
import { type Bundle, composeBundle, composeRing, type PushPayload } from "./compose.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const service = createClient(URL_, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

interface Sub {
  id: string;
  profile_id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
  failures: number;
}

const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), {
    status,
    headers: { "content-type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: { ring?: { room?: string; conversation?: string } } = {};
  try {
    body = await req.json();
  } catch { /* empty body = cron drain */ }

  if (body.ring) return await ring(req, body.ring);
  return json(await drain());
});

async function drain() {
  const { data, error } = await service.rpc("claim_push_batch", { p_limit: 500 });
  if (error) throw error;
  const bundles = (data ?? []) as (Bundle & { recipient_id: string })[];
  if (bundles.length === 0) return { people: 0, sent: 0 };
  const subs = await subsFor(bundles.map((b) => b.recipient_id));
  let sent = 0;
  await Promise.all(bundles.map(async (b) => {
    const payload = composeBundle(b);
    for (const s of subs.get(b.recipient_id) ?? []) {
      if (await send(s, payload, b.last_kind === "message" ? "high" : "normal", 86400)) sent++;
    }
  }));
  return { people: bundles.length, sent };
}

async function ring(req: Request, r: { room?: string; conversation?: string }) {
  const auth = req.headers.get("authorization") ?? "";
  if (!r.room || !r.conversation || !/^Bearer\s+\S+/i.test(auth)) {
    return json({ error: "room, conversation and a signed-in caller required" }, 400);
  }
  // As the caller, so call_ring_targets can check they own the room.
  const asCaller = createClient(URL_, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: auth } },
  });
  const { data, error } = await asCaller.rpc("call_ring_targets", {
    p_room: r.room,
    p_conversation: r.conversation,
  });
  if (error) return json({ error: error.message }, 403);
  const targets = (data ?? []) as { recipient_id: string; caller_name: string }[];
  if (targets.length === 0) return json({ rung: 0 });
  const subs = await subsFor(targets.map((t) => t.recipient_id));
  const payload = composeRing(targets[0].caller_name, r.room, r.conversation);
  let rung = 0;
  for (const t of targets) {
    for (const s of subs.get(t.recipient_id) ?? []) {
      // A ring that arrives a minute late is worse than none.
      if (await send(s, payload, "high", 60)) rung++;
    }
  }
  return json({ rung });
}

async function subsFor(ids: string[]): Promise<Map<string, Sub[]>> {
  const out = new Map<string, Sub[]>();
  if (ids.length === 0) return out;
  const { data, error } = await (service as SupabaseClient)
    .from("push_subscription")
    .select("id, profile_id, endpoint, p256dh, auth, failures")
    .in("profile_id", ids);
  if (error) throw error;
  for (const s of (data ?? []) as Sub[]) {
    out.set(s.profile_id, [...(out.get(s.profile_id) ?? []), s]);
  }
  return out;
}

async function send(
  s: Sub,
  payload: PushPayload,
  urgency: "normal" | "high",
  ttl: number,
): Promise<boolean> {
  try {
    const url = new URL(s.endpoint);
    if (url.protocol !== "https:") throw new Error("https only");
    await assertPublicHost(url);
    const bodyBytes = await encryptWebPush(
      new TextEncoder().encode(JSON.stringify(payload)),
      s.p256dh,
      s.auth,
    );
    const res = await fetch(url, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
      headers: {
        "Content-Encoding": "aes128gcm",
        "Content-Type": "application/octet-stream",
        TTL: String(ttl),
        Urgency: urgency,
      },
      body: bodyBytes,
    });
    await res.body?.cancel();
    if (res.status === 404 || res.status === 410) {
      await service.from("push_subscription").delete().eq("id", s.id);
      return false;
    }
    if (res.ok) {
      await service.from("push_subscription")
        .update({ last_ok_at: new Date().toISOString(), failures: 0 })
        .eq("id", s.id);
      return true;
    }
    throw new Error(`distributor said ${res.status}`);
  } catch (e) {
    const failures = s.failures + 1;
    // Twenty straight failures (~a day of cron runs with traffic) = gone.
    if (failures >= 20) {
      await service.from("push_subscription").delete().eq("id", s.id);
    } else {
      await service.from("push_subscription").update({ failures }).eq("id", s.id);
    }
    console.warn(`push to subscription ${s.id} failed: ${e instanceof Error ? e.message : e}`);
    return false;
  }
}
