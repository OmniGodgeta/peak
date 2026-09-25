-- Phase 8: Audio Calls and Live Rooms Schema

CREATE TYPE call_type AS ENUM ('audio', 'video');
CREATE TYPE call_status AS ENUM ('pending', 'active', 'ended', 'missed');

CREATE TABLE call_rooms (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    owner_id UUID REFERENCES profile(id) ON DELETE SET NULL,
    title TEXT,
    is_public BOOLEAN DEFAULT false,
    space_id UUID REFERENCES community(id) ON DELETE CASCADE, -- if it's a room in a Space
    max_participants INTEGER DEFAULT 4,
    encryption_enabled BOOLEAN DEFAULT true
);

CREATE TABLE call_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    room_id UUID NOT NULL REFERENCES call_rooms(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES profile(id) ON DELETE CASCADE,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    left_at TIMESTAMPTZ,
    is_muted BOOLEAN DEFAULT false,
    is_speaking BOOLEAN DEFAULT false,
    device_info JSONB,
    UNIQUE(room_id, user_id)
);

-- RLS Policies

ALTER TABLE call_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE call_participants ENABLE ROW LEVEL SECURITY;

-- Call Rooms: Anyone can see public rooms; owners/members of space can see space rooms.
CREATE POLICY "Public calls are viewable by anyone" ON call_rooms
    FOR SELECT USING (is_public = true);

CREATE POLICY "Space members can view space rooms" ON call_rooms
    FOR SELECT USING (space_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM community_member
        WHERE community_id = call_rooms.space_id AND member_id = auth.uid()
    ));

CREATE POLICY "Only owner can create rooms" ON call_rooms
    FOR INSERT WITH CHECK (auth.uid() = owner_id);

-- Call Participants: Join if you have access to the room.
CREATE POLICY "Participants can view participants in their room" ON call_participants
    FOR SELECT USING (EXISTS (
        SELECT 1 FROM call_rooms 
        WHERE id = call_participants.room_id 
        AND (is_public = true OR space_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM community_member
            WHERE community_id = call_rooms.space_id AND member_id = auth.uid()
        ) OR owner_id = auth.uid())
    ));

CREATE POLICY "Users can join rooms they have access to" ON call_participants
    FOR INSERT WITH CHECK (EXISTS (
        SELECT 1 FROM call_rooms 
        WHERE id = call_participants.room_id 
        AND (is_public = true OR space_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM community_member
            WHERE community_id = call_rooms.space_id AND member_id = auth.uid()
        ) OR owner_id = auth.uid())
    ));

CREATE POLICY "Users can leave rooms" ON call_participants
    FOR UPDATE USING (user_id = auth.uid());
