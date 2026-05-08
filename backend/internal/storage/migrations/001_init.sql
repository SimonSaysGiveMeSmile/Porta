CREATE TABLE IF NOT EXISTS devices (
    id              UUID PRIMARY KEY,
    public_key      BYTEA NOT NULL,
    apns_token      TEXT,
    platform        TEXT NOT NULL DEFAULT 'ios',
    trusted_mode    TEXT NOT NULL DEFAULT 'manual',
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS devices_public_key_uniq ON devices (public_key);

CREATE TABLE IF NOT EXISTS shares (
    id              UUID PRIMARY KEY,
    owner_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    token           TEXT NOT NULL UNIQUE,
    title           TEXT,
    file_count      INT NOT NULL DEFAULT 0,
    total_bytes     BIGINT NOT NULL DEFAULT 0,
    manifest        JSONB NOT NULL DEFAULT '[]'::jsonb,
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS shares_owner_idx ON shares (owner_device_id, created_at DESC);
CREATE INDEX IF NOT EXISTS shares_expires_idx ON shares (expires_at);

CREATE TABLE IF NOT EXISTS sessions (
    id              UUID PRIMARY KEY,
    share_id        UUID NOT NULL REFERENCES shares(id) ON DELETE CASCADE,
    requester_ip    INET,
    requester_ua    TEXT,
    status          TEXT NOT NULL DEFAULT 'pending',
    approved_at     TIMESTAMPTZ,
    rejected_at     TIMESTAMPTZ,
    closed_at       TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sessions_share_idx ON sessions (share_id, created_at DESC);
CREATE INDEX IF NOT EXISTS sessions_status_idx ON sessions (status);

CREATE TABLE IF NOT EXISTS transfers (
    id              UUID PRIMARY KEY,
    session_id      UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    bytes_sent      BIGINT NOT NULL DEFAULT 0,
    bytes_total     BIGINT NOT NULL DEFAULT 0,
    status          TEXT NOT NULL DEFAULT 'pending',
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS transfers_session_idx ON transfers (session_id);
