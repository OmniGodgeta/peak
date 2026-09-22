-- Enable the pgvector extension to work with embeddings
CREATE EXTENSION IF NOT EXISTS vector;

-- Add embedding column to the 'post' table for content-based recommendations
-- 1536 is the standard dimension for OpenAI embeddings
ALTER TABLE public.post 
ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Add embedding column to the 'profile' table for user-interest-based recommendations
ALTER TABLE public.profile 
ADD COLUMN IF NOT EXISTS embedding vector(1536);

-- Create an index for faster similarity searches (using HNSW for better performance)
-- This index is on the post table to allow fast "similar posts" queries
CREATE INDEX IF NOT EXISTS posts_embedding_idx ON public.post 
USING hnsw (embedding vector_cosine_ops);

-- Create an index on the profile table
CREATE INDEX IF NOT EXISTS profiles_embedding_idx ON public.profile 
USING hnsw (embedding vector_cosine_ops);

-- Create an RPC for finding posts similar to a given vector (e.g., user interest or post content)
CREATE OR REPLACE FUNCTION public.match_posts (
  query_embedding vector(1536),
  match_threshold float,
  match_count int
)
RETURNS TABLE (
  id uuid,
  content text,
  author_id uuid,
  similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id,
    p.body, -- Assuming 'body' is the content column
    p.author_id,
    1 - (p.embedding <=> query_embedding) AS similarity
  FROM public.post p
  WHERE 1 - (p.embedding <=> query_embedding) > match_threshold
  ORDER BY p.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

-- Create an RPC for finding profiles (users) similar to a given vector
CREATE OR REPLACE FUNCTION public.match_profiles (
  query_embedding vector(1536),
  match_threshold float,
  match_count int
)
RETURNS TABLE (
  id uuid,
  handle text,
  similarity float
)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    pr.id,
    pr.handle,
    1 - (pr.embedding <=> query_embedding) AS similarity
  FROM public.profile pr
  WHERE 1 - (pr.embedding <=> query_embedding) > match_threshold
  ORDER BY pr.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;
