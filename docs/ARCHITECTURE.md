# Porta Architecture

## Goals

- Ephemeral, user-approved transfers. Backend is a coordinator, not storage.
- Direct P2P via WebRTC; TURN relay fallback; DTLS-encrypted end-to-end.
- Receiver needs only a browser — no app, no account.

## Components

```
  iOS app                         Web receiver
    │                                   │
    │  REST (auth, share, session)      │  REST (request, session)
    │  WSS  (signaling)                 │  WSS  (signaling)
    ▼                                   ▼
 ┌──────────────────────────────────────────────┐
 │            Backend (Go / Fiber)              │
 │  - share/session/device services             │
 │  - WebRTC signaling hub (Redis pub/sub)      │
 │  - APNS dispatcher                           │
 │  - TURN credential issuer (HMAC)             │
 └──────┬────────────────────────────┬──────────┘
        │                            │
        ▼                            ▼
    PostgreSQL                     Redis
   (durable metadata)           (sessions, pubsub)

        ┌────────────────────────────────┐
        │   coturn (STUN/TURN relay)     │
        └────────────────────────────────┘
```

## Data model (summary)

- `devices`        — one per installed app, with public key + APNS token.
- `shares`         — a live link: `token`, `owner_device_id`, `expires_at`.
- `sessions`       — a receiver's request against a share.
- `transfers`      — byte accounting per session.

See `backend/internal/storage/migrations/` for SQL.

## Share token design

- 128-bit random share ID, base62-encoded (`4f9a2x...`).
- Signed with HMAC-SHA256 on a server secret; carries `exp`.
- Public URL: `https://porta.app/s/<token>`.

## Session lifecycle

1. Sender → `POST /v1/shares` → `{share_id, token, share_url}`.
2. Receiver opens `/s/<token>` in browser; hits `POST /v1/shares/<token>/requests`.
3. Server creates `session` in `PENDING`, fires silent APNS to owner device.
4. Sender app wakes, user taps approve → `POST /v1/sessions/<id>/approve`.
5. Both sides open `WSS /v1/signal/<session_id>`; exchange SDP + ICE.
6. WebRTC attempts direct; falls back to coturn if needed.
7. Byte transfer over a data channel (16 KiB-chunked, resumable).

## Security

- Device identity: Ed25519 keypair in iOS Keychain; registered on first launch.
- Auth: device attests by signing a server-issued nonce → JWT (30 min).
- Share tokens signed + expiring. Sessions scoped to a share.
- TURN credentials: short-lived (TTL 60s), HMAC'd from shared secret.
- No file bytes touch backend storage. Backend sees metadata + envelope only.

## Why Go + Fiber

- Cheap per-connection cost for WebSocket signaling hub.
- Simple operational profile (single static binary).
- Fiber is thin, fast, and keeps the surface area small for an MVP.
