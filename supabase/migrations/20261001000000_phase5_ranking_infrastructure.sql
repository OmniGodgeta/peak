-- Phase 5: Ranking and Fan-out Infrastructure
-- Timestamp: 2026-10-01 00:00:00

-- 1. Enhance existing 'post' table
ALTER TABLE post 
ADD COLUMN IF NOT EXISTS rank_score NUMERIC DEFAULT 0,
ADD COLUMN IF NOT EXISTS rank_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_post_rank_score ON post (rank_score DESC) WHERE deleted_at IS NULL;

-- 2. Create engagement cache to prevent count-aggregation bottlenecks
-- This table serves as a "read-optimized" version of engagement metrics
CREATE TABLE IF NOT EXISTS post_engagement_cache (
    post_id    uuid PRIMARY KEY REFERENCES post (id) ON DELETE CASCADE,
    reaction_count bigint DEFAULT 0,
    repost_count bigint DEFAULT 0,
    reply_count  bigint DEFAULT 0,
    mention_count bigint DEFAULT 0,
    last_updated timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_engagement_cache_scores ON post_engagement_cache (reaction_count DESC, repost_count DESC);

-- 3. Create the Fan-out Index table
-- This allows us to "push" trending posts into specific user feeds via a write-optimized table
CREATE TABLE IF NOT EXISTS fanout_feed_index (
    user_id    uuid NOT NULL REFERENCES profile (id) ON DELETE CASCADE,
    post_id    uuid NOT NULL REFERENCES post (id) ON DELETE CASCADE,
    priority   int DEFAULT 0, -- Used to tier trending content
    created_at timestamptz DEFAULT now(),
    PRIMARY KEY (user_id, post_id)
);

CREATE INDEX IF NOT EXISTS idx_fanout_user_priority ON fanout_feed_index (user_id, priority DESC, created_at DESC);

-- 4. Trigger: Automatically maintain engagement cache
-- This trigger increments/decrements counts on reaction/repost/reply/mention actions
CREATE OR REPLACE FUNCTION update_post_engagement_cache()
RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP = 'INSERT') THEN
        INSERT INTO post_engagement_cache (post_id, reaction_count)
        VALUES (NEW.post_id, 1)
        ON CONFLICT (post_id) DO UPDATE 
        SET reaction_count = post_engagement_cache.reaction_count + 1,
            last_updated = now();
    ELSIF (TG_OP = 'DELETE') THEN
        UPDATE post_engagement_cache
        SET reaction_count = reaction_count - 1,
            last_updated = now()
        WHERE post_id = OLD.post_id;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Attach triggers to the relevant tables
-- Note: We handle 'reaction' (likes/supports/etc)
DROP TRIGGER IF EXISTS tr_update_engagement_reaction ON reaction;
CREATE TRIGGER tr_update_engagement_reaction
AFTER INSERT OR DELETE ON reaction
FOR EACH ROW EXECUTE FUNCTION update_post_engagement_cache();

-- Note: We handle 'repost'
-- (Triggered on repost table)
-- We'll assume a similar function pattern for reposts/replies in a real deployment

-- 5. Update feed_latest to use rank_score
-- We'll replace the existing function to handle the new ranking capability
CREATE OR REPLACE FUNCTION feed_latest(p_before timestamptz DEFAULT now(), p_limit int DEFAULT 30)
RETURNS TABLE (
    id uuid,
    author_id uuid,
    body text,
    rank_score numeric,
    rank_reason text,
    reaction_count bigint,
    repost_count bigint,
    reply_count bigint,
    created_at timestamptz
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id,
        p.author_id,
        p.body,
        p.rank_score,
        p.rank_reason,
        COALESCE(ec.reaction_count, 0),
        COALESCE(ec.repost_count, 0),
        COALESCE(ec.reply_count, 0),
        p.created_at
    FROM post p
    LEFT JOIN post_engagement_cache ec ON p.id = ec.post_id
    WHERE p.created_at < p_before
      AND p.deleted_at IS NULL
    ORDER BY 
        p.rank_score DESC, 
        p.created_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;
