import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY"); // Placeholder for real usage

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface EmbedRequest {
  type: "post" | "profile";
  id: string;
  text: string;
}

/**
 * Generates a pseudo-random vector for development/testing.
 * This ensures the flow works even without an active OpenAI API key.
 * Dimension: 1536
 */
function generateDevEmbedding(text: string): number[] {
  // Create a deterministic seed from the text to make it "feel" real for testing
  let hash = 0;
  for (let i = 0; i < text.length; i++) {
    hash = ((hash << 5) - hash) + text.charCodeAt(i);
    hash |= 0; 
  }

  const vector = new Array(1536);
  for (let i = 0; i < 1536; i++) {
    // Use hash + index to create pseudo-random but consistent values
    const val = Math.sin(hash + i) * Math.PI;
    vector[i] = val;
  }
  
  // Normalize the vector (important for cosine similarity)
  const magnitude = Math.sqrt(vector.reduce((sum, val) => sum + val * val, 0));
  return vector.map(v => v / magnitude);
}

/**
 * Integration point for real OpenAI embeddings.
 */
async function getRealEmbedding(text: string): Promise<number[]> {
  if (!OPENAI_API_KEY) {
    console.log("No OPENAI_API_KEY found. Using dev-mode embedding.");
    return generateDevEmbedding(text);
  }

  try {
    const response = await fetch("https://api.openai.com/v1/embeddings", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        input: text,
        model: "text-embedding-3-small", // efficient and 1536 dims
      }),
    });

    const data = await response.json();
    return data.data[0].embedding;
  } catch (error) {
    console.error("Failed to fetch real embedding, falling back to dev-mode:", error);
    return generateDevEmbedding(text);
  }
}

serve(async (req) => {
  try {
    const { type, id, text } = (await req.json()) as EmbedRequest;

    if (!type || !id || !text) {
      return new Response(JSON.stringify({ error: "Missing required fields: type, id, or text" }), { status: 400 });
    }

    console.log(`Processing embedding for ${type} [ID: ${id}]`);

    // 1. Generate the embedding
    const embedding = await getRealEmbedding(text);

    // 2. Update the database
    let error;
    if (type === "post") {
      const { error: updateErr } = await supabase
        .from("post")
        .update({ embedding })
        .eq("id", id);
      error = updateErr;
    } else if (type === "profile") {
      const { error: updateErr } = await supabase
        .from("profile")
        .update({ embedding })
        .eq("id", id);
      error = updateErr;
    } else {
      return new Response(JSON.stringify({ error: "Invalid type. Use 'post' or 'profile'." }), { status: 400 });
    }

    if (error) throw error;

    return new Response(JSON.stringify({ message: "Embedding updated successfully", type, id }), { status: 200 });

  } catch (err) {
    console.error("Error processing embedding:", err.message);
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});
