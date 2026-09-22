// ranking-engine — calculates and decays rank_score for posts.
// Should be called via a cron job or a scheduled task.
//
// logic:
// 1. Fetch recent posts (last 48h) from post_engagement_cache.
// 2. Calculate score: (reactions * 1) + (reposts * 3) + (replies * 5).
// 3. Apply temporal decay (score / (age_in_hours + 2)^1.5).
// 4. Update post.rank_score and post.rank_reason.

import { createClient } from "jsr:@supabase/supabase-js@2";

interface EngagementMetrics {
  post_id: string;
  reaction_count: number;
  repost_count: number;
  reply_count: number;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  // In production, this would be called with a Service Role Key to bypass RLS
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const db = createClient(supabaseUrl, supabaseServiceKey);

  try {
    console.log("Starting ranking calculation...");

    // 1. Fetch metrics for all posts in the last 48 hours
    // We use the engagement cache to avoid scanning the whole post table
    const { data: metrics, error: fetchErr } = await db
      .from("post_engagement_cache")
      .select("post_id, reaction_count, repost_count, reply_count")
      .order("reaction_count", { ascending: false })
      .limit(500); // Process top 500 most engaged recent posts

    if (fetchErr) throw fetchErr;
    if (!metrics || metrics.length === 0) {
      return new Response(JSON.stringify({ message: "No engagement found to rank." }), { status: 200 });
    }

    const now = new Date();
    const updates: { id: string; score: number; reason: string }[] = [];

    for (const m of metrics) {
      // Fetch the post's creation time to calculate decay
      const { data: post, error: pErr } = await db
        .from("post")
        .select("created_at")
        .eq("id", m.post_id)
        .single();

      if (pErr || !post) continue;

      const createdAt = new Date(post.created_at);
      const ageInHours = (now.getTime() - createdAt.getTime()) / (1000 * 60 * 60);

      // Skip very old posts in this batch
      if (ageInHours > 72) continue;

      // 2. Calculate Base Score
      // Weighting: Likes/Reactions=1, Reposts=3, Replies=5
      const baseScore = 
        (m.reaction_count * 1) + 
        (m.repost_count * 3) + 
        (m.reply_count * 5);

      // 3. Apply Temporal Decay (Gravity)
      // We use a power law decay so things "fall" out of the feed.
      const decay = Math.pow(ageInHours + 2, 1.5);
      const finalScore = baseScore / decay;

      // 4. Determine the "Reason" (for transparency)
      let reason = "Trending in your area";
      if (m.repost_count > m.reaction_count * 2) {
        reason = "Highly discussed";
      } else if (m.reaction_count > 20) {
        reason = "Popular right now";
      } else if (m.reply_count > 5) {
        reason = "Active conversation";
      }

      updates.push({
        id: m.post_id,
        score: parseFloat(finalScore.toFixed(4)),
        reason: reason
      });
    }

    // 5. Batch update the posts
    // Since we can't do a bulk update of different values easily in supabase-js 
    // without a custom RPC, we'll use a loop or a specialized RPC call.
    // For this implementation, we'll use the easiest path: a loop with a single transaction if possible.
    
    console.log(`Updating ${updates.length} posts...`);
    
    for (const u of updates) {
        await db.from("post")
          .update({ 
            rank_score: u.score,
            rank_reason: u.reason 
          })
          .eq("id", u.id);
    }

    return new Response(JSON.stringify({ 
      message: "Ranked successfully", 
      processed: updates.length 
    }), { status: 200 });

  } catch (err) {
    console.error("Ranking error:", err);
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});
