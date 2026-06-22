-- Group conversations: roster, per-group epoch, and wrapped group-key blobs.

CREATE TABLE __DATABASE_SCHEMA__.groups (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(255) NOT NULL,
    owner_id    UUID NOT NULL,
    epoch       BIGINT NOT NULL DEFAULT 0,
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

-- Opaque wrapped group-key blobs, one per (group, epoch, member).
CREATE TABLE __DATABASE_SCHEMA__.group_keys (
    group_id     UUID NOT NULL REFERENCES __DATABASE_SCHEMA__.groups (id) ON DELETE CASCADE,
    epoch        BIGINT NOT NULL,
    recipient_id UUID NOT NULL,
    wrapped_key  TEXT NOT NULL,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    delivered    BOOLEAN NOT NULL DEFAULT FALSE,
    PRIMARY KEY (group_id, epoch, recipient_id)
);

-- Fetch a member's undelivered wrapped keys for the /inbox groupKeys[] pull.
CREATE INDEX idx_group_keys_recipient_undelivered
    ON __DATABASE_SCHEMA__.group_keys (recipient_id) WHERE delivered = FALSE;
