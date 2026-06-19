-- Public keys directory table for E2E keys (signing + encryption).

CREATE TABLE IF NOT EXISTS __DATABASE_SCHEMA__.public_keys (
    user_id UUID PRIMARY KEY,
    signing_public_key TEXT NOT NULL,
    encryption_public_key TEXT NOT NULL,
    uploaded_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Index to support queries by recency if needed
CREATE INDEX IF NOT EXISTS idx_public_keys_uploaded_at ON __DATABASE_SCHEMA__.public_keys (uploaded_at DESC);
