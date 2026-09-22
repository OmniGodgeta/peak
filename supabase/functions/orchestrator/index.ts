// orchestrator — The central heartbeat for Phase 5.
//
// This function manages the end-to-end lifecycle of a trending post:
// 1. Ranking: Triggers the calculation of scores.
// 2. Fanout: Identifies new trending posts and triggers the broadcast.
// 3. Maintenance: Cleans up old data or logs.
//
// In production, this is called by a scheduled cron job every 5-15 minutes.

import { createClient } from "jsr:@supabase/supabase-js@2";

const RANKING_THRESHOLD = 5.0; // Minimum score to trigger a global/community fanout

Deno.serve(async (req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(supabaseUrl, supabaseServiceKey);

  try {
    console.log("--- Starting Orchestration Cycle ---");

    // STEP 1: TRIGGER RANKING
    // We call our own ranking-engine function via HTTP.
    // (In a real environment, this is an internal service-to-service call)
    console.log("Step 1: Triggering ranking-engine...");
    const rankingRes = await fetch(
      `${Deno.env.get("SUPABASE_FUNCTION_URL")}/ranking-engine`, 
      { method: "POST", headers: { Authorization: `Bearer ${supabaseServiceKey}` } }
    );
    
    if (!rankingRes.ok) {
        const errText = await rankingRes.text();
        throw new Error(`Ranking-engine failed: ${errText}`);
    }
    const rankingResult = await rankingRes.json();
    console.log("Ranking outcome:", rankingResult);

    // STEP 2: IDENTIFY & FANOUT
    console.log("Step 2: Identifying posts for fanout...");
    
    // Find posts that are trending but haven't been fanned out yet.
    const { data: trendingPosts, error: fetchErr } = await db
      .from("post")
      .select("id, rank_score, rank_reason")
      .eq("is_fanned_out", false)
      .gt("rank_score", RANKING_THRESHOLD);

    if (fetchErr) throw fetchErr;

    if (trendingPosts && trendingPosts.length > 0) {
      console.log(`Found ${trendingPosts.length} posts to fanout.`);

      for (const post of trendingPosts) {
        console.log(`Fanning out post: ${post.id} (Score: ${post.rank_score})`);

        // Trigger the fanout-executor
        const fanoutRes = await fetch(
          `${Deno.env.get("SUPABASE_FUNCTION_URL")}/fanout-executor`,
          {
            method: "POST",
            headers: { 
              "Content-Type": "application/json",
              Authorization: `Bearer ${supabaseServiceKey}` 
            },
            body: JSON.stringify({
              postId: post.id,
              mode: "global" // For this implementation, all highly ranked posts go global
            })
          }
        );

        if (!fanoutRes.ok) {
          console.error(`Fanout failed for ${post.id}: ${await fanoutRes.text()}`);
          continue; // Don't stop the whole cycle for one failure
        }

        // Mark as fanned out so we don't repeat this next time.
        await db.from("post").update({ is_fanned_out: true }).eq("id", post.id);
      }
    } else {
      console.log("No new trending posts found for fanout.");
    }

    console.log("--- Orchestration Cycle Complete ---");
    return new Response(JSON.stringify({ status: "success" }), { status: 200 });

  } catch (err) {
    console.error("Orchestrator error:", err);
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});
