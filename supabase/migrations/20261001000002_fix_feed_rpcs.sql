
-- Function to return trending posts based on rank_score
CREATE OR REPLACE FUNCTION feed_trending(p_limit int DEFAULT 30)
RETURNS TABLE (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility text,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle text,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to text,
    depth int
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, p.author_handle, p.author_domain,
    p.author_display_name, p.author_is_teen, p.author_avatar_path,
    p.reaction_count, p.reply_count, p.repost_count, p.viewer_reacted, p.viewer_reposted,
    p.media, p.title, p.long_form, p.is_pinned, p.community_label, p.community_label_note,
    p.author_flair, p.channel_id, p.channel_name, p.reason, p.reply_to, p.depth
  FROM post p
  ORDER BY p.rank_score DESC, p.created_at DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Reset feed_latest to be strictly chronological
CREATE OR REPLACE FUNCTION feed_latest(p_limit int DEFAULT 30)
RETURNS TABLE (
    id uuid,
    body text,
    content_warning text,
    is_sensitive boolean,
    visibility text,
    created_at timestamptz,
    edited_at timestamptz,
    author_id uuid,
    author_handle text,
    author_domain text,
    author_display_name text,
    author_is_teen boolean,
    author_avatar_path text,
    reaction_count bigint,
    reply_count bigint,
    repost_count bigint,
    viewer_reacted boolean,
    viewer_reposted boolean,
    media jsonb,
    title text,
    long_form boolean,
    is_pinned boolean,
    community_label text,
    community_label_note text,
    author_flair text,
    channel_id uuid,
    channel_name text,
    reason text,
    reply_to text,
    depth int
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    p.id, p.body, p.content_warning, p.is_sensitive, p.visibility,
    p.created_at, p.edited_at, p.author_id, p.author_handle, p.author_domain,
    p.author_display_name, p.author_is_teen, p.author_avatar_path,
    p.reaction_count, p.reply_count, p.repost_count, p.viewer_reacted, p.viewer_reposted,
    p.media, p.title, p.long_form, p.is_pinned, p.community_label, p.community_label_note,
    p.author_flair, p.channel_id, p.channel_name, p.reason, p.reply_to, p.depth
  FROM post p
  ORDER BY p.created_at DESC
  LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;
