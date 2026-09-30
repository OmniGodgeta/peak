// purge-media — removes the Storage objects of posts the 30-day purge has
// hard-deleted, plus replaced thumbnails.
//
// SQL can't delete from storage.objects (storage.protect_delete), so
// purge_expired_deletions() and the poster-replaced trigger only queue paths
// in media_pending_delete. This drains that queue through the Storage API.
//
// POST {SUPABASE_URL}/functions/v1/purge-media  — pg_cron calls it daily.
// It only ever removes paths the database already queued, so any caller can
// at most make it run early; the queue itself is service-role only.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { drain } from "./drain.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), {
      status: 405,
      headers: { "content-type": "application/json" },
    });
  }

  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const result = await drain({
    async claim(limit) {
      const { data, error } = await db
        .from("media_pending_delete")
        .select("bucket_id, object_name")
        .order("queued_at")
        .limit(limit);
      if (error) throw error;
      return data ?? [];
    },
    async remove(bucket, names) {
      const { error } = await db.storage.from(bucket).remove(names);
      if (error) throw error;
    },
    async forget(bucket, names) {
      const { error } = await db
        .from("media_pending_delete")
        .delete()
        .eq("bucket_id", bucket)
        .in("object_name", names);
      if (error) throw error;
    },
  });

  return new Response(JSON.stringify(result), {
    headers: { "content-type": "application/json" },
  });
});
