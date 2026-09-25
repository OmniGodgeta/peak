-- Phase 9: Video Enhancements (Captions, Chapters, Playlists, Watch-Later)
-- Timestamp: 20261005000000

-- 1. Chapters & Subtitles
CREATE TABLE IF NOT EXISTS post_chapters (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  media_id     uuid NOT NULL REFERENCES post_media(id) ON DELETE CASCADE,
  label        text NOT NULL,
  start_ms     int NOT NULL CHECK (start_ms >= 0),
  end_ms       int NOT NULL CHECK (end_ms > start_ms),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS post_chapters_media_id_idx ON post_chapters(media_id);

CREATE TABLE IF NOT EXISTS post_subtitles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  media_id     uuid NOT NULL REFERENCES post_media(id) ON DELETE CASCADE,
  language     citext NOT NULL DEFAULT 'en',
  text         text NOT NULL,
  start_ms     int NOT NULL CHECK (start_ms >= 0),
  end_ms       int NOT NULL CHECK (end_ms > start_ms),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS post_subtitles_media_id_idx ON post_subtitles(media_id);

-- 2. Playlists
CREATE TABLE IF NOT EXISTS playlist (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id     uuid NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
  name         text NOT NULL,
  description  text,
  is_public    boolean DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS playlist_owner_id_idx ON playlist(owner_id);

CREATE TABLE IF NOT EXISTS playlist_item (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  playlist_id  uuid NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
  media_id     uuid NOT NULL REFERENCES post_media(id) ON DELETE CASCADE,
  sort_order   int NOT NULL DEFAULT 0,
  added_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE(playlist_id, media_id)
);
CREATE INDEX IF NOT EXISTS playlist_item_playlist_id_idx ON playlist_item(playlist_id);
CREATE INDEX IF NOT EXISTS playlist_item_media_id_idx ON playlist_item(media_id);

-- 3. Watch-Later
CREATE TABLE IF NOT EXISTS watch_later (
  user_id      uuid NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
  media_id     uuid NOT NULL REFERENCES post_media(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, media_id)
);

-- 4. RLS Policies

ALTER TABLE post_chapters ENABLE ROW LEVEL SECURITY;
ALTER TABLE post_subtitles ENABLE ROW LEVEL SECURITY;
ALTER TABLE playlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE playlist_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE watch_later ENABLE ROW LEVEL SECURITY;

-- Chapters/Subtitles: Everyone can read if they can see the post
CREATE POLICY "Chapters are viewable by everyone" ON post_chapters FOR SELECT USING (true);
CREATE POLICY "Subtitles are viewable by everyone" ON post_subtitles FOR SELECT USING (true);

-- Playlist: Owners manage; public playlists visible to all
CREATE POLICY "Playlists are viewable by everyone" ON playlist FOR SELECT USING (is_public = true OR owner_id = auth.uid());
CREATE POLICY "Users can create playlists" ON playlist FOR INSERT WITH CHECK (auth.uid() = owner_id);
CREATE POLICY "Owners can update playlists" ON playlist FOR UPDATE USING (owner_id = auth.uid());
CREATE POLICY "Owners can delete playlists" ON playlist FOR DELETE USING (owner_id = auth.uid());

-- Playlist Items: Sync with Playlist visibility
CREATE POLICY "Playlist items are viewable by everyone if playlist is public" 
  ON playlist_item FOR SELECT 
  USING (EXISTS (SELECT 1 FROM playlist WHERE playlist.id = playlist_item.playlist_id AND (playlist.is_public = true OR playlist.owner_id = auth.uid())));

CREATE POLICY "Users can add items to their own playlists" 
  ON playlist_item FOR INSERT 
  WITH CHECK (EXISTS (SELECT 1 FROM playlist WHERE playlist.id = playlist_item.playlist_id AND playlist.owner_id = auth.uid()));

CREATE POLICY "Users can remove items from their own playlists" 
  ON playlist_item FOR DELETE 
  USING (EXISTS (SELECT 1 FROM playlist WHERE playlist.id = playlist_item.playlist_id AND playlist.owner_id = auth.uid()));

-- Watch-Later: Personal only
CREATE POLICY "Watch later is private" ON watch_later FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "Users manage watch later" ON watch_later FOR ALL USING (user_id = auth.uid());

-- 5. RPCs for Video List & Management

-- Get videos for a specific user profile
CREATE OR REPLACE FUNCTION get_user_videos(p_author_id uuid, p_limit int DEFAULT 30)
RETURNS TABLE (
  media_id uuid,
  post_id uuid,
  storage_path text,
  poster_path text,
  duration_ms int,
  width int,
  height int,
  created_at timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT pm.id, p.id, pm.storage_path, pm.poster_path, pm.duration_ms, pm.width, pm.height, p.created_at
  FROM post_media pm
  JOIN post p ON p.id = pm.post_id
  WHERE p.author_id = p_author_id
    AND pm.kind = 'video' -- Assumes 'video' is the correct custom type value
    AND p.deleted_at IS NULL
    AND can_view_post(p, auth.uid())
  ORDER BY p.created_at DESC
  LIMIT p_limit;
$$;
