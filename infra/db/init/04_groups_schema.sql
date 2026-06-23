-- Group conversations: roster only. Messages are sent as one independent 1:1 copy per member,
-- so the Server never holds any group key material.

CREATE TABLE __DATABASE_SCHEMA__.groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    owner_id    UUID NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Current roster. One row per (group, member).
CREATE TABLE __DATABASE_SCHEMA__.group_members (
    group_id  UUID NOT NULL REFERENCES __DATABASE_SCHEMA__.groups (id) ON DELETE CASCADE,
    user_id   UUID NOT NULL,
    joined_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (group_id, user_id)
);

-- List a user's groups efficiently.
CREATE INDEX idx_group_members_user ON __DATABASE_SCHEMA__.group_members (user_id);
