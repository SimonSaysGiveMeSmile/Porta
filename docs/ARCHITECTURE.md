# Porta Architecture

## Core insight

The hard part of device-to-device transfer is reachability: the phone isn't
addressable from the public internet. Porta's architecture sidesteps it.

Instead of NAT-punching in, **the sender opens a reverse tunnel out**. The
backend exposes a public URL; requests hit the backend, get forwarded back
through the tunnel to the phone, and the phone streams the file bytes as the
response. It is a tiny, purpose-built ngrok that runs inside an iOS app.

Consequences:

- No STUN / TURN / WebRTC on day one. A WebSocket is enough.
- The browser receiver only needs vanilla `fetch` — no WebRTC peer.
- Reachability works behind any NAT: carrier, enterprise, hotel wifi, LTE.
- Bytes touch the backend, but are never persisted.

## Components

```
 iOS app (sender)                   Browser (receiver)
     │                                    │
     │  outbound WSS                      │  HTTPS
     │  /v1/tunnel                        │  /s/<token>  /p/<session>/*
     ▼                                    ▼
 ┌────────────────────────────────────────────┐
 │        Porta backend (Go / Fiber)          │
 │  - auth (device keypair → JWT)             │
 │  - shares + sessions + APNS                │
 │  - tunnel hub (share_id → live tunnel)     │
 │  - /p proxy: request → tunnel → response   │
 └──────────────────┬─────────────────────────┘
                    │
                    ▼
                PostgreSQL
              (durable metadata)
```

## The tunnel wire format

A single WebSocket per active share. Frames are binary:

```
┌────────┬───────────────────────┬──────────────┐
│ op (1) │ requestID (16)        │ payload (n)  │
└────────┴───────────────────────┴──────────────┘
```

Opcodes:

| Op      | Dir            | Meaning                              |
| ------- | -------------- | ------------------------------------ |
| `OPEN`  | edge → sender  | begin request; payload = JSON header |
| `HEAD`  | sender → edge  | response status + headers (JSON)     |
| `BODY`  | bidi           | body chunk; payload = raw bytes      |
| `END`   | bidi           | stream complete                      |
| `ERR`   | sender → edge  | error message (utf-8)                |
| `CANCEL`| edge → sender  | receiver disconnected                |

Requests are multiplexed — a single tunnel can handle several concurrent
downloads. The Go server lives in `backend/internal/tunnel/`; the Swift
client is in `ios/PortaCore/Sources/PortaCore/TunnelClient.swift`. Both use
the exact same framing.

## End-to-end flow

1. iOS app generates an Ed25519 keypair (Keychain), signs a nonce,
   receives a JWT.
2. User selects files → `POST /v1/shares` → `{id, token, share_url}`.
3. App opens `wss://.../v1/tunnel?share=<id>&token=<jwt>`. Ownership checked.
4. App hands the sender a `TunnelClient` wrapping a `FileServer` responder.
5. Receiver opens `https://porta.app/s/<token>` → landing page, sees files.
6. Receiver taps "Request files" → `POST /v1/shares/by-token/<token>/requests`.
7. Backend creates session (pending), APNS-wakes the owner device.
8. User taps the notification → app shows approval sheet → `POST
   /v1/sessions/<id>/approve`.
9. Browser polls `/v1/sessions/<id>/status`, sees `approved`, navigates to
   `/p/<session>/files/<name>`.
10. Backend finds the share's tunnel, fires an `OPEN` frame, pipes `HEAD` +
    `BODY` frames straight into the HTTP response.

If the sender closes the app, the WebSocket dies, the hub entry is removed,
and subsequent `/p` requests get `502 sender offline`.

## Security

- **Device identity**: Ed25519 keypair, private key in Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Public key is the
  row key in `devices`.
- **Auth**: server-issued 32-byte nonce; signed with device private key;
  exchanged for a 30-min HS256 JWT. No passwords.
- **Share tokens**: `base64url(id[16] || expUnix[8]) . base64url(HMAC256(payload))`.
  Rejected client-side without a DB hit if malformed or expired.
- **Session authorization**: the tunnel is keyed by share ID; the `/p/` route
  checks the session is `approved` *and* belongs to that share *and* the
  tunnel is connected.
- **Bytes in flight**: WSS is TLS. The backend's memory sees body chunks for
  milliseconds. No disk persistence.

## What's explicitly *not* here

- No WebRTC / STUN / TURN. (We may reintroduce a direct path later for LAN
  transfers, but the MVP bar is "works globally, always".)
- No cloud storage. Shares disappear when the tunnel disconnects.
- No accounts. Device = identity.
- No background tunnels. iOS will kill the socket after a few seconds in
  background; the UX mirrors FaceTime rather than a server.

## Horizontal scaling (later)

The tunnel hub is in-process, keyed by `shareID`. To scale, the obvious move
is: sticky-route both the tunnel WebSocket and the `/p/` request to the same
backend instance (by share ID, via consistent hash). Redis pub/sub becomes a
secondary fallback if a `/p/` request lands on an instance that doesn't hold
the tunnel.

For an MVP, a single backend node behind Fly.io or Hetzner is plenty.
