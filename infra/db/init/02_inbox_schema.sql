-- Cold tier of the server-owned inbox.

CREATE TABLE __DATABASE_SCHEMA__.inbox (
    message_id   UUID PRIMARY KEY,
    recipient_id UUID NOT NULL,
    sender_id    UUID,
    payload      TEXT NOT NULL,
    signature    TEXT NOT NULL,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Fetch a recipient's pending messages in arrival order for GET /inbox.
CREATE INDEX idx_inbox_recipient_created ON __DATABASE_SCHEMA__.inbox (recipient_id, created_at);

