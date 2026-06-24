-- Signal pre-key directory. One bundle per user (identity + registration id + signed pre-key),
-- plus a consumable pool of one-time pre-keys handed out one per opened session.

CREATE TABLE IF NOT EXISTS __DATABASE_SCHEMA__.public_keys (
    user_id                 UUID PRIMARY KEY,
    registration_id         INTEGER NOT NULL,
    identity_key            TEXT NOT NULL,
    signed_prekey_id        INTEGER NOT NULL,
    signed_prekey_public    TEXT NOT NULL,
    signed_prekey_signature TEXT NOT NULL,
    uploaded_at             TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Consumable pool of one-time pre-keys; the server pops one per session handout and deletes it.
CREATE TABLE IF NOT EXISTS __DATABASE_SCHEMA__.one_time_prekeys (
    user_id    UUID NOT NULL,
    key_id     INTEGER NOT NULL,
    public_key TEXT NOT NULL,
    PRIMARY KEY (user_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_one_time_prekeys_user ON __DATABASE_SCHEMA__.one_time_prekeys (user_id);
