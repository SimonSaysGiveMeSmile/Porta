# Verifying Porta

Three things are worth verifying independently, because each one fails in a
different way:

1. **Local loop** — backend + web receiver on the same machine, no tunnel,
   no iPhone. Proves the wire protocol is correct.
2. **Global via Cloudflare / ngrok** — same local backend, exposed to the
   public internet through a third-party tunnel. Proves the share URL works
   from a different network.
3. **LAN (iOS only)** — the iOS app alone, no backend, discovered over
   Bonjour. Proves the `_porta._tcp.` mDNS path.

You don't need Xcode for (1) and (2) — the `fake-sender` CLI plays the role
of the iPhone. (3) requires Xcode because `LANHost` only runs on an Apple
device's Network framework.

---

## 1. Local loop (60 seconds, no network)

One command. Spins up Postgres, builds the backend, builds a CLI "fake"
sender, exercises every endpoint, downloads the file, and diffs the bytes:

```bash
./scripts/verify.sh
```

Expected tail output:

```
[verify] ✓ end-to-end transfer verified (sha256 <hex>)
[verify] logs: /tmp/porta-verify.<pid>
```

If it fails, the same directory has `backend.log`, `sender.log`, and
`migrate.log` — start there.

What each step proves:

| Step                                   | Proves                                       |
| -------------------------------------- | -------------------------------------------- |
| `POST /v1/auth/nonce` + `verify`       | Ed25519 signing path is wired end-to-end      |
| `POST /v1/shares`                      | Share token generation + HMAC signing        |
| `WS /v1/tunnel`                        | Reverse-tunnel auth + frame protocol         |
| `POST /v1/shares/by-token/.../requests`| Public receiver flow                         |
| `POST /v1/sessions/:id/approve`        | Auto-approver loop (polls `/sessions/pending`)|
| `GET /p/:sessionId/files/...`          | Proxy read + write through tunnel            |
| `sha256` match                         | No byte corruption over the multiplex        |

---

## 2. Global (via Cloudflare Tunnel or ngrok)

Keep the backend running locally; expose it with a third-party tunnel. No
cloud deployment required.

### 2a. Cloudflare (zero config, free)

Terminal A — backend:
```bash
# env must point to the public URL cloudflared will print
export PORTA_PUBLIC_BASE_URL="https://<picked-name>.trycloudflare.com"
cd backend && make run
```

Terminal B — tunnel:
```bash
./scripts/tunnel-cloudflare.sh 8080
```

In practice you'll run the tunnel *first*, note the `*.trycloudflare.com`
URL, stop the backend (Ctrl-C), set `PORTA_PUBLIC_BASE_URL` to that URL, and
restart the backend. Share links are generated against `PORTA_PUBLIC_BASE_URL`
so they need to be set correctly before you run `POST /v1/shares`.

Terminal C — fake sender:
```bash
cd backend && go run ./cmd/fake-sender \
  -backend "$PORTA_PUBLIC_BASE_URL" \
  -file /path/to/some/file
```

Note the `share url:` line printed to stdout, then open it on a phone's
browser on a different network (turn wifi off on your phone to really prove
it). You should see the landing page, tap "Request files", watch the CLI
approve the request, and get a native browser download.

### 2b. ngrok

Same flow with `./scripts/tunnel-ngrok.sh 8080`. Requires a free ngrok
account and `ngrok config add-authtoken <token>` first.

### What to check

- `curl $PORTA_PUBLIC_BASE_URL/health` returns `{"ok":true,...}` from any
  network.
- The share URL in `sender.log` is a `*.trycloudflare.com` / `*.ngrok-free.app`
  URL, not `localhost`.
- Downloading from a phone on cellular (wifi off) still works.

### Gotchas

- The free Cloudflare quick tunnel URL changes every restart. That's fine
  for testing; for anything stable you'd need a named tunnel (`cloudflared
  tunnel create …`), which requires a Cloudflare account.
- WebSocket upgrades work on both cloudflared quick tunnels and ngrok.
- Large files: cloudflared buffers less aggressively than ngrok's free tier;
  ngrok free has a warning page on first visit that older browsers may not
  render well.

---

## 3. LAN (iOS, no backend at all)

`PortaCore` ships a `LANHost` that binds `NWListener` with a
`_porta._tcp.` Bonjour service. Sender and receiver must be on the same
wifi; the receiver finds the sender via mDNS discovery (or by typing
`http://<device-name>.local:<port>/share` into Safari).

Package-level tests already prove the HTTP path — from the repo root:

```bash
cd ios/PortaCore && swift test
```

Expected: `LANHostTests.testManifestEndpoint` passes. It starts the listener
on an ephemeral port, connects over raw TCP, and reads back the manifest.

For the full LAN UX (Bonjour discovery across devices), open the Xcode
project and run on two devices; that path is not covered by headless tests.

---

## Reference: ports and env

| Component        | Port  | Notes                              |
| ---------------- | ----- | ---------------------------------- |
| Postgres         | 5432  | docker compose                     |
| Backend          | 8080  | `PORTA_ADDR`                       |
| Web dev server   | 5173  | `cd web && npm run dev`            |
| LAN HTTP server  | auto  | `NWListener` picks a free port      |

Key env vars (`backend/.env.example` is the full list):

```
PORTA_DATABASE_URL=postgres://porta:porta@localhost:5432/porta?sslmode=disable
PORTA_PUBLIC_BASE_URL=http://localhost:8080  # set to tunnel URL when going global
PORTA_SHARE_HMAC_SECRET=... (>= 16 chars)
PORTA_JWT_SECRET=... (>= 16 chars)
```
