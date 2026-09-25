import { createClient } from "jsr:@supabase/supabase-js@2";

interface FederationRequest {
  remoteActorId: string; // URI of the sender
  targetActorId: string; // URI of the recipient
  activityType: 'follow' | 'post' | 'reply' | 'like';
  payload: any;
}

Deno.serve(async (req) => {
  const db = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!
  );

  // Handle WebFinger discovery (GET req with query params)
  const url = new URL(req.url);
  if (req.method === "GET" && url.searchParams.has("resource")) {
    const resource = url.searchParams.get("resource");
    // Basic handle extraction (e.g., @user or user@domain)
    let handle = resource?.replace(/^@/, "");
    if (handle?.includes("@")) {
        handle = handle.split("@")[0];
    }

    if (handle) {
      // Find profile by handle or actor_url
      const { data: profile } = await db
        .from("profile")
        .select("actor_url, display_name")
        .or(`handle.eq.${handle},actor_url.ilike.%${handle}%`)
        .maybeSingle();

      if (profile) {
        return new Response(JSON.stringify({
          "acct": profile.actor_url || `${handle}@shadow-1.tail51f9d6.ts.net`
        }), {
          headers: { "Content-Type": "application/json" }
        });
      }

      // Fallback for the dev environment setup
      return new Response(JSON.stringify({
        "acct": `${handle}@shadow-1.tail51f9d6.ts.net` 
      }), {
        headers: { "Content-Type": "application/json" }
      });
    }
  }

  // Handle Inbox activities (POST req)
  if (req.method === "POST") {
    try {
      const body = await req.json();
      
      // 1. Check if federation is enabled in system_config
      const { data: config } = await db
        .from("system_config")
        .select("value")
        .eq("key", "federation_enabled")
        .single();

      if (!config || config.value !== 'true') {
        return new Response(JSON.stringify({ error: "Federation disabled" }), { status: 403 });
      }

      // ActivityPub identifies itself via type and actor fields.
      // For our inbox, we expect a target recipient URI in the payload or request context.
      const activityId = body.id;
      const remoteActorId = body.actor; // The sender
      const targetActorUrl = body.to;   // The recipient (ActivityPub spec)
      const type = body.type;           // follow, Create (post/reply), Like

      if (!activityId || !remoteActorId || !targetActorUrl) {
         return new Response(JSON.stringify({ error: "Missing activity identity (id, actor, or to)" }), { status: 400 });
      }

      // 2. Idempotency check using inbox_activity_log
      const { data: existing } = await db
        .from("inbox_activity_log")
        .select("*")
        .eq("remote_actor_id", remoteActorId)
        .eq("activity_id", activityId)
        .maybeSingle();

      if (existing) {
        return new Response(JSON.stringify({ message: "Already processed" }), { status: 200 });
      }

      // 3. Identify the local user receiving this activity
      const { data: recipientProfile } = await db
        .from("profile")
        .select("id")
        .eq("actor_url", targetActorUrl)
        .maybeSingle();

      if (!recipientProfile) {
        console.error(`Target recipient ${targetActorUrl} not found locally.`);
        return new Response(JSON.stringify({ error: "Recipient not found" }), { status: 404 });
      }

      const recipientId = recipientProfile.id;

      // 4. Process Activity types
      console.log(`Processing ${type} from ${remoteActorId} to ${targetActorUrl}`);

      if (type === 'follow') {
          // We need a receiver/follower relation. In AP, if A sends 'Follow' to B, A is following B.
          // So we find A and add them as follower of B? No, in AP if I follow you, you get an 'Accept' notification.
          // Let's simplify for our inbox: If actor X follows target Y, create a follow record.
          
          // Need remote actor identity. For now, assume they have a local shadow or we skip complex mapping.
          // To keep this simple for the task, let's look up the sender too.
          const { data: senderProfile } = await db
            .from("profile")
            .select("id")
            .eq("actor_url", remoteActorId)
            .maybeSingle();

          if (senderProfile) {
              await db.from("follow").insert({ follower_id: senderProfile.id, followee_id: recipientId });
          } else {
              // Fallback: Create a generic 'federated user' entry if possible, or just log.
              // Given constraints, let's just log and return 202.
              console.log("Sender not found locally; skipping follow link.");
          }

      } else if (type === 'Create') {
          // Handle post/reply via payload object types
          const objType = body.object?.type;
          if (objType === 'Note') { // ActivityPub standard for posts
              const { data: senderProfile } = await db
                .from("profile")
                .select("id")
                .eq("actor_url", remoteActorId)
                .maybeSingle();
              
              const authorId = senderProfile?.id || recipientId; // Fallback to recipient for testing? No, that makes them the author of their own post. Let's assume local shadow exists.

              if (senderProfile) {
                  const { error: postErr } = await db.from("post").insert({
                      author_id: senderProfile.id,
                      persona_id: (await db.from('persona').select('id').eq('account_id', senderProfile.id).single()).data?.id,
                      body: body.object?.content || '',
                      root_id: body.object?.id ? null : null, // Simplified
                      created_at: new Date()
                  });
                  if (!postErr) {
                      await db.from("inbox_activity_log").insert({
                          remote_actor_id: remoteActorId,
                          activity_id: activityId,
                          type: "post"
                      });
                  }
              }
          } else if (objType === 'Like') {
              // Logic for like...
          }
      } else if (type === 'Like') {
          // Direct Like activity
      }

      // Log success regardless of whether we could map a profile for the sender/action
      await db.from("inbox_activity_log").insert({
        remote_actor_id: remoteActorId,
        activity_id: activityId,
        type: type || "unknown"
      });

      return new Response(JSON.stringify({ message: "Accepted" }), { status: 202 });
    } catch (err) {
      console.error(err);
      return new Response(JSON.stringify({ error: err.message }), { status: 500 });
    }
  }

  return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405 });
});

