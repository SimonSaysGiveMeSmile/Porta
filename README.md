# Porta — AirDrop with links

Ephemeral, global, device-to-device file sharing. A user creates a live link
from their iPhone, shares the URL, approves incoming requests in-app, and
streams files directly from the phone to any browser.

The backend is a thin coordinator. It issues share links, wakes the sender
via APNS, and runs a reverse tunnel so the browser can reach the phone — but
file bytes are never persisted.

## Why "reverse tunnel" instead of WebRTC

Porta's sender device opens an **outbound** WebSocket to the backend. All
receiver traffic flows back through that socket. This sidesteps the usual
NAT-punching / STUN / TURN pile: outbound connections work everywhere
(carrier NAT, hotel wifi, enterprise firewall, LTE), and the browser only
needs vanilla HTTPS.

See `docs/ARCHITECTURE.md` for wire format and flows.

## Repository layout

```
porta/
├── backend/        Go (Fiber) API + reverse-tunnel hub + APNS
├── web/            TypeScript + Vite receiver (landing, request, download)
├── ios/            PortaCore (SwiftPM) + SwiftUI app + Share Extension
├── infra/          Docker, docker-compose, nginx for the web receiver
├── docs/           Architecture notes
├── scripts/        Dev helpers
└── .github/        CI workflows
```

## Quick start

```bash
# 1. Infra: Postgres only (no TURN needed).
docker compose -f infra/docker-compose.yml up -d

# 2. Backend.
cd backend
cp .env.example .env
make migrate
make run   # :8080

# 3. Web receiver (dev server with /v1 proxy to backend).
cd ../web
npm install
npm run dev   # :5173
```

Open `http://localhost:5173/s/<token>` with a token from `POST /v1/shares`
to exercise the receiver flow.

## Core endpoints

- `POST /v1/shares` — sender creates a live link.
- `GET /v1/tunnel` — sender opens the outbound reverse tunnel (WS).
- `GET /s/:token` — receiver landing page.
- `POST /v1/shares/by-token/:token/requests` — receiver asks for access.
- `POST /v1/sessions/:id/approve` — sender approves in-app.
- `GET /p/:sessionId/files/<name>` — public download proxied through tunnel.

## Phases

1. **MVP** — this repo. Reverse tunnel, approval flow, single-file downloads.
2. **Reliability** — resumable range requests, reconnect-and-resume on
   network switches, health pings, transfer queue.
3. **Social** — trusted devices, auto-accept, presence.
4. **Ecosystem** — macOS menu bar app, Android, desktop companion.
