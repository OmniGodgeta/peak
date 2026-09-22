
-- Phase 5: Orchestration Prep
-- Timestamp: 2026-10-01 00:05:00

-- Add a flag to track if a post has already been processed by the fanout-executor.
-- This prevents redundant fanout operations during every orchestration cycle.
ALTER TABLE post 
ADD COLUMN IF NOT EXISTS is_fanned_out BOOLEAN DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_post_needs_fanout ON post (rank_score) 
WHERE is_fanned_out = FALSE AND rank_score > 0;
