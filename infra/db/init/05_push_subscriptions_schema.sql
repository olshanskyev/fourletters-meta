-- Web Push (VAPID) subscriptions. One active subscription per user (single-device model):

CREATE TABLE IF NOT EXISTS __DATABASE_SCHEMA__.push_subscriptions (
    user_id    UUID PRIMARY KEY REFERENCES __DATABASE_SCHEMA__.users(id) ON DELETE CASCADE,
    endpoint   TEXT NOT NULL,
    p256dh     TEXT NOT NULL,
    auth       TEXT NOT NULL,
    user_agent VARCHAR(512),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP
);
