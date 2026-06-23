-- Cold tier of the server-owned inbox.
-- Composite key (message_id, recipient_id): one row per recipient (a group message is sent as one
-- independent 1:1 copy per member, sharing the message_id). group_id is NULL for 1:1.


CREATE TABLE __DATABASE_SCHEMA__.inbox (
    message_id   UUID NOT NULL,
    recipient_id UUID NOT NULL,
    sender_id    UUID,
    payload      TEXT NOT NULL,
    signature    TEXT NOT NULL,
    group_id     UUID,
    created_at   TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (message_id, recipient_id)
);

-- Fetch a recipient's pending messages in arrival order for GET /inbox.
CREATE INDEX idx_inbox_recipient_created ON __DATABASE_SCHEMA__.inbox (recipient_id, created_at);

