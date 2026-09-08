// app-version — the release manifest the in-app updater polls.
//
// GET {SUPABASE_URL}/functions/v1/app-version  → 200, JSON, no auth.
// One key per platform; the app ignores platforms and fields it doesn't know:
//
//   {
//     "android": {
//       "versionName": "1.0.0",
//       "versionCode": 1,
//       "apkUrl": "https://…/peak-1.0.0-release.apk",
//       "sha256": "<hex>",
//       "notes": "shown in the update sheet",
//       "minSupportedVersionCode": 1,
//       "publishedAt": "2026-09-08T23:20:00Z"
//     }
//   }
//
// Source of truth is the `app_release` table (world-readable via RLS); CI
// rewrites the row on a tagged release. verify_jwt is off for this function
// (config.toml) because the updater runs before sign-in.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface ReleaseRow {
  platform: string;
  version_name: string;
  version_code: number;
  apk_url: string | null;
  sha256: string | null;
  notes: string | null;
  min_supported_version_code: number;
  published_at: string;
}

function shape(row: ReleaseRow) {
  return {
    versionName: row.version_name,
    versionCode: row.version_code,
    apkUrl: row.apk_url,
    sha256: row.sha256,
    notes: row.notes,
    minSupportedVersionCode: row.min_supported_version_code,
    publishedAt: row.published_at,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: CORS });
  }
  if (req.method !== "GET") {
    return json({ error: "method not allowed" }, 405);
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
  );

  const { data, error } = await db
    .from("app_release")
    .select(
      "platform, version_name, version_code, apk_url, sha256, notes, min_supported_version_code, published_at",
    )
    .returns<ReleaseRow[]>();

  if (error) {
    return json({ error: "lookup failed" }, 500);
  }

  const manifest: Record<string, ReturnType<typeof shape>> = {};
  for (const row of data ?? []) {
    manifest[row.platform] = shape(row);
  }

  return json(manifest, 200, { "Cache-Control": "public, max-age=300" });
});

function json(
  payload: unknown,
  status = 200,
  extra: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", ...CORS, ...extra },
  });
}
