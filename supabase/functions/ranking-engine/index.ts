// ranking-engine — writes a global recency score onto recent posts.
//
// Per-viewer signals (mutual follow, last visit, author diversity) live in
// rank.ts and in recommend_posts_for_user. This job only decays by age, so
// likes, reposts, replies, and follower counts cannot move a post.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { scorePost } from "./rank.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(supabaseUrl, supabaseServiceKey);

  try {
    const since = new Date(Date.now() - 72 * 3_600_000).toISOString();
    const { data: posts, error } = await db
      .from("post")
      .select("id, created_at, author_id")
      .is("deleted_at", null)
      .is("reply_to", null)
      .eq("visibility", "public")
      .gte("created_at", since)
      .limit(500);
    if (error) throw error;
    if (!posts || posts.length === 0) {
      return Response.json({
        message: "No recent posts to rank.",
        processed: 0,
      });
    }

    const nowMs = Date.now();
    let processed = 0;
    for (const post of posts) {
      const createdAtMs = new Date(post.created_at).getTime();
      const ranked = scorePost(
        {
          id: post.id,
          createdAtMs,
          authorId: post.author_id,
          mutual: false,
        },
        { nowMs, lastVisitMs: null },
      );
      const { error: updateErr } = await db.from("post").update({
        rank_score: Number(ranked.score.toFixed(4)),
        rank_reason: ranked.reason,
      }).eq("id", post.id);
      if (updateErr) throw updateErr;
      processed += 1;
    }

    return Response.json({ message: "Ranked successfully", processed });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error("Ranking error:", message);
    return Response.json({ error: message }, { status: 500 });
  }
});
