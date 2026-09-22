import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

// A list of prohibited patterns/regexes (placeholder for semantic AI)
const PROHIBITED_PATTERNS = [
  /hate\s?speech/i,
  /\b(bad_word_1|bad_word_2|bad_word_3)\b/i, // Replace with real examples
  /explicit_content_regex/i,
];

const PROHIBITED_REASON = "Automatic toxicity detection";

serve(async (req) => {
  try {
    const payload = await req.json();
    
    // Supabase Webhook payloads typically wrap the new record in a 'record' field
    const newPost = payload.record;

    if (!newPost || !newPost.body) {
      return new Response("No post body found in payload.", { status: 400 });
    }

    const body = newPost.body;
    const postId = newPost.id;
    const authorId = newPost.author_id;

    console.log(`[Sentinel] Scanning post: ${postId} from user: ${authorId}`);

    // 1. Perform pattern matching
    let isToxic = false;
    let matchedPattern = "";

    for (const pattern of PROHIBITED_PATTERNS) {
      if (pattern.test(body)) {
        isToxic = true;
        matchedPattern = pattern.toString();
        break;
      }
    }

    // 2. If toxic, take action
    if (isToxic) {
      console.log(`[Sentinel] !!! TOXICITY DETECTED in post ${postId} (Pattern: ${matchedPattern})`);
      
      // Execute Supabase RPC or direct update to hide the post and log it
      // Note: In a real environment, this would use a Supabase Service Role key 
      // to bypass RLS.
      
      // For this implementation, we assume we've set up a service-role client.
      // We'll simulate the database call logic here.
      
      /*
      const { error } = await supabase
        .from('post')
        .update({ is_hidden: true, moderation_flag: 'toxic' })
        .eq('id', postId);

      if (error) throw error;

      await supabase.from('moderation_logs').insert({
        post_id: postId,
        reason: PROHIBITED_REASON,
        pattern_matched: matchedPattern,
        severity: 'medium'
      });
      */

      return new Response(JSON.stringify({
        action: 'hidden',
        reason: PROHIBITED_REASON,
        postId
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ action: 'passed', postId }), { status: 200, headers: { "Content-Type": "application/json" } });

  } catch (err) {
    console.error(`[Sentinel] Error: ${err.message}`);
    return new Response(err.message, { status: 500 });
  }
});
