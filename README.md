# Porta — AirDrop with Links

Ephemeral, global, device-to-device file sharing. Users create a live link from
their iPhone, share the URL with anyone, approve the transfer request in-app,
and stream files over WebRTC (direct P2P first, TURN relay as fallback).

Porta is **not** cloud storage — the backend only coordinates sessions and
signals; file bytes never persist in the cloud.

## Repository layout

```
porta/
├── backend/   Go (Fiber) API + WebRTC signaling + APNS push
├── web/       Web receiver (vanilla TS + WebRTC)
├── ios/       SwiftUI iOS app scaffold (share extension, WebRTC client)
├── infra/     coturn, Docker, deployment scripts
├── docs/      Architecture notes
└── scripts/   Dev helpers
```

## Quick start (local dev)

```bash
# 1. Boot infra (Postgres, Redis, coturn)
docker compose -f infra/docker-compose.yml up -d

# 2. Run backend
cd backend
cp .env.example .env
make migrate
make run

# 3. Serve web receiver
cd ../web
npm install
npm run dev
```

Backend listens on `:8080`, web receiver on `:5173`.

## Core flows

- `POST /v1/shares` — sender creates a live link, gets a signed share URL.
- `GET /s/:token` — receiver opens link in any browser.
- `POST /v1/shares/:token/requests` — receiver requests access.
- APNS push wakes the sender device; user approves in-app.
- `WS /v1/signal/:sessionId` — WebRTC SDP/ICE exchange.
- Bytes stream peer-to-peer (DTLS-encrypted). Relay via coturn if needed.

See `docs/ARCHITECTURE.md` for detail.

## Phases

1. **MVP** — iOS app, web receiver, signaling, manual approval, direct P2P.
2. **Reliability** — TURN relay, reconnects, resume, transfer queue.
3. **Social** — trusted devices, auto-accept, presence.
4. **Ecosystem** — macOS, Windows, Android.
