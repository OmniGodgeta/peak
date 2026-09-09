// export — assemble the caller's account into a single JSON archive and hand
// back a short-lived signed download URL.
//
// POST {SUPABASE_URL}/functions/v1/export  (JWT required)
//   → 200 { url, filename, bytes }   url is a signed link into the private
//                                    `exports` bucket, valid ~1 hour.
//
// The heavy lifting is the `export_my_data()` SQL function (SECURITY DEFINER,
// keyed on auth.uid()). This function only routes the result to storage so the
// client gets a real file it can save, on web and mobile alike.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const asUser = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: userData, error: userErr } = await asUser.auth.getUser();
  if (userErr || !userData.user) return json({ error: "unauthorized" }, 401);
  const uid = userData.user.id;

  const { data: archive, error: rpcErr } = await asUser.rpc("export_my_data");
  if (rpcErr) return json({ error: rpcErr.message }, 500);

  const body = new TextEncoder().encode(JSON.stringify(archive, null, 2));
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const filename = `peak-export-${stamp}.json`;
  const path = `${uid}/${filename}`;

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { error: upErr } = await admin.storage
    .from("exports")
    .upload(path, body, { contentType: "application/json", upsert: true });
  if (upErr) return json({ error: upErr.message }, 500);

  const { data: signed, error: signErr } = await admin.storage
    .from("exports")
    .createSignedUrl(path, 3600, { download: filename });
  if (signErr || !signed) return json({ error: "could not sign url" }, 500);

  return json({ url: signed.signedUrl, filename, bytes: body.length }, 200);
});

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}
