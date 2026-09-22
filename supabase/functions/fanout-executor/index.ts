// fanout-executor — Pushes trending posts into user-specific feed indices.
//
// Trigger: Called by ranking-engine when a post hits a threshold.
//
// Logic:
// 1. Receives a post_id.
// 2. Identifies "target audiences" (e.g., all active users, or users following a community).
// 3. Performs a batch insert into `fanout_feed_index`.
//
// This allows 'Discovery' feeds to be a simple SELECT from fanout_feed_index
// instead of a complex join across posts, reactions, and follows.

import { createClient } from "jsr:@supabase/supabase-js@2";

interface FanoutRequest {
  postId: string;
  mode: "global" | "community" | "interest";
  targetId?: string; // community_id or interest_id
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(supabaseUrl, supabaseServiceKey);

  let input: FanoutRequest;
  try {
    input = await req.json();
  } catch {
    return new Response("Bad JSON", { status: 400 });
  }

  const { postId, mode, targetId } = input;

  try {
    console.log(`Starting fanout for post ${postId} (mode: ${mode})`);

    let userIds: string[] = [];

    if (mode === "global") {
      // For massive viral posts, we target all users who have logged in recently.
      // In a real system, this might be handled via a queue/worker to avoid timeouts.
      const { data: activeUsers, error: userErr } = await db
        .from("profile")
        .select("id")
        .limit(5000); // Capped for this implementation

      if (userErr) throw userErr;
      if (activeUsers) userIds = activeUsers.map(u => u.id);

    } else if (mode === "community" && targetId) {
      // Target members of a specific community.
      const { data: members, error: memberErr } = await db
        .from("community_member") // Assuming this table exists based on roadmap/context
        .select("user_id")
        .eq("community_id", targetId);

      if (memberErr) throw memberErr;
      if (members) userIds = members.map(m => m.user_id);

    } else {
        return new Response(JSON.stringify({ error: "Invalid mode or missing targetId" }), { status: 400 });
    }

    if (userIds.length === 0) {
      return new Response(JSON.stringify({ message: "No target users found" }), { status: 200 });
    }

    // Batch insert into fanout_feed_index
    // We use chunks to avoid massive payload errors in Postgres
    const chunkSize = 500;
    let processedCount = 0;

    for (let i = 0; i < userIds.length; i += chunkSize) {
      const chunk = userIds.slice(i, i + chunkSize).map(uid => ({
        user_id: uid,
        post_id: postId,
        priority: mode === "global" ? 1 : 10 // Community posts are higher priority
      }));

      const { error: insertErr } = await db
        .from("fanout_feed_index")
        .upsert(chunk, { onConflict: 'user_id,post_id' });

      if (insertErr) throw insertErr;
      processedCount += chunk.length;
    }

    console.log(`Fanout complete. Processed ${processedCount} users.`);
    return new Response(JSON.stringify({ 
      message: "Fanout successful", 
      processed: processedCount 
    }), { status: 200 });

  } catch (err) {
    console.error("Fanout error:", err);
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});
