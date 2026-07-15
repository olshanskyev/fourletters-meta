-- Cold tier of the server-owned inbox. Single-copy storage for both 1:1 and group messages: the
-- payload is stored once per message_id; who still owes a receipt lives in inbox_pending.
-- group_id is NULL for 1:1 messages.

CREATE TABLE __DATABASE_SCHEMA__.inbox (
    message_id  UUID PRIMARY KEY,
    sender_id   UUID,
    payload     TEXT NOT NULL,
    group_id    UUID,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- One row per recipient who still owes a signed receipt. Deleting the last row for a message_id
-- means every recipient acknowledged, so the parent inbox payload is dropped (trigger below).
CREATE TABLE __DATABASE_SCHEMA__.inbox_pending (
    message_id   UUID NOT NULL REFERENCES __DATABASE_SCHEMA__.inbox (message_id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL,
    PRIMARY KEY (message_id, recipient_id)
);

-- Fetch a recipient's pending messages in arrival order for GET /inbox.
CREATE INDEX idx_inbox_pending_recipient ON __DATABASE_SCHEMA__.inbox_pending (recipient_id);

-- Enforce "last pending row deleted => drop the parent payload" in the database.
CREATE OR REPLACE FUNCTION __DATABASE_SCHEMA__.drop_inbox_when_delivered()
    RETURNS TRIGGER AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM __DATABASE_SCHEMA__.inbox_pending
        WHERE message_id = OLD.message_id
    ) THEN
        DELETE FROM __DATABASE_SCHEMA__.inbox WHERE message_id = OLD.message_id;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_inbox_pending_cleanup
    AFTER DELETE ON __DATABASE_SCHEMA__.inbox_pending
    FOR EACH ROW
    EXECUTE FUNCTION __DATABASE_SCHEMA__.drop_inbox_when_delivered();

