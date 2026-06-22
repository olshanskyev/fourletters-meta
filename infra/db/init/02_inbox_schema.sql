-- Cold tier of the server-owned inbox.
-- Composite key (message_id, recipient_id): one row per recipient (group messages
-- fan out to one row per member). group_id and epoch are NULL for 1:1.


CREATE TABLE __DATABASE_SCHEMA__.inbox (
    message_id   UUID NOT NULL,
    recipient_id UUID NOT NULL,
    sender_id    UUID,
    payload      TEXT NOT NULL,
    signature    TEXT NOT NULL,
    group_id     UUID,
    epoch        BIGINT,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (message_id, recipient_id)
);

-- Fetch a recipient's pending messages in arrival order for GET /inbox.
CREATE INDEX idx_inbox_recipient_created ON __DATABASE_SCHEMA__.inbox (recipient_id, created_at);

