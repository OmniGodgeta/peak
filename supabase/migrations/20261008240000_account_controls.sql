-- federation_account_controls.sql

-- New migration to handle account export/import for federation mobility.

CREATE TABLE IF NOT EXISTS account_exports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profile(id) ON DELETE CASCADE,
    exported_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    data JSONB NOT NULL, -- Contains posts, follows, likes, etc.
    expires_at TIMESTAMPTZ NOT NULL,
    token TEXT UNIQUE NOT NULL -- For secure one-time import
);

CREATE INDEX idx_account_exports_user_id ON account_exports(user_id);
CREATE INDEX idx_account_exports_token ON account_exports(token);

-- Function to generate an export package
CREATE OR REPLACE FUNCTION export_account(p_user_id UUID)
RETURNS JSONB AS $$
DECLARE
    v_data JSONB;
    v_expiry TIMESTAMPTZ := NOW() + INTERVAL '30 days';
BEGIN
    -- Aggregating essential data
    SELECT jsonb_build_object(
        'profile', (SELECT to_jsonb(p) FROM profile p WHERE p.id = p_user_id),
        'posts', (SELECT jsonb_agg(to_jsonb(po)) FROM post po WHERE po.author_id = p_user_id),
        'follows', (SELECT jsonb_agg(to_jsonb(f)) FROM follow f WHERE f.follower_id = p_user_id),
        'likes', (SELECT jsonb_agg(to_jsonb(l)) FROM reaction l WHERE l.actor_id = p_user_id AND l.kind = 'like')
    ) INTO v_data;

    INSERT INTO account_exports (user_id, data, expires_at, token)
    VALUES (p_user_id, v_data, v_expiry, encode(gen_random_bytes(32), 'hex'));

    RETURN (SELECT to_jsonb(e) FROM account_exports e WHERE e.user_id = p_user_id ORDER BY exported_at DESC LIMIT 1);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
