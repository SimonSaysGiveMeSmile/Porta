#!/usr/bin/env bash
# scripts/verify.sh
#
# End-to-end smoke test for Porta. Starts Postgres via docker compose, boots
# the backend, runs the fake-sender CLI, exercises the receiver flow, and
# diffs the downloaded bytes against the source file.
#
# Exit 0 = every step passed.
# Exit non-zero = first failing step prints a reason.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_PID=""
FAKE_PID=""
LOGDIR="${TMPDIR:-/tmp}/porta-verify.$$"
mkdir -p "$LOGDIR"

log() { printf '\033[36m[verify]\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[verify]\033[0m %s\n' "$*"; exit 1; }

cleanup() {
  [[ -n "$FAKE_PID"    ]] && kill "$FAKE_PID"    2>/dev/null || true
  [[ -n "$BACKEND_PID" ]] && kill "$BACKEND_PID" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT

# -- 1. dependencies -------------------------------------------------------
command -v go           >/dev/null || fail "go not installed"
command -v docker       >/dev/null || fail "docker not installed"
command -v curl         >/dev/null || fail "curl not installed"
command -v jq           >/dev/null || fail "jq not installed (brew install jq)"

# -- 2. postgres -----------------------------------------------------------
log "starting postgres"
docker compose -f "$ROOT/infra/docker-compose.yml" up -d postgres >/dev/null

for i in $(seq 1 30); do
  if docker compose -f "$ROOT/infra/docker-compose.yml" exec -T postgres pg_isready -U porta >/dev/null 2>&1; then
    break
  fi
  sleep 1
  [[ $i == 30 ]] && fail "postgres not ready"
done

# -- 3. backend env --------------------------------------------------------
export PORTA_ADDR=":8080"
export PORTA_ENV="dev"
export PORTA_DATABASE_URL="postgres://porta:porta@localhost:5432/porta?sslmode=disable"
export PORTA_PUBLIC_BASE_URL="http://localhost:8080"
export PORTA_SHARE_HMAC_SECRET="verify-share-hmac-secret-32bytes!"
export PORTA_JWT_SECRET="verify-jwt-secret-32-bytes-long!!"
export PORTA_SHARE_TTL_HOURS=1
export PORTA_JWT_TTL_MINUTES=30

# -- 4. backend ------------------------------------------------------------
log "building backend"
(cd "$ROOT/backend" && go build -o "$LOGDIR/porta" ./cmd/porta)

log "running migrations"
(cd "$ROOT/backend" && "$LOGDIR/porta" -migrate) >"$LOGDIR/migrate.log" 2>&1

log "booting backend (logs: $LOGDIR/backend.log)"
(cd "$ROOT/backend" && "$LOGDIR/porta") >"$LOGDIR/backend.log" 2>&1 &
BACKEND_PID=$!

for i in $(seq 1 30); do
  if curl -fsS http://localhost:8080/health >/dev/null 2>&1; then break; fi
  sleep 0.3
  [[ $i == 30 ]] && fail "backend did not come up — see $LOGDIR/backend.log"
done

# -- 5. fixture file -------------------------------------------------------
FIXTURE="$LOGDIR/fixture.bin"
dd if=/dev/urandom of="$FIXTURE" bs=1024 count=2048 status=none   # 2 MiB
FIXTURE_SHA=$(shasum -a 256 "$FIXTURE" | awk '{print $1}')

# -- 6. fake sender --------------------------------------------------------
log "building fake-sender"
(cd "$ROOT/backend" && go build -o "$LOGDIR/fake-sender" ./cmd/fake-sender)

log "launching fake-sender (logs: $LOGDIR/sender.log)"
"$LOGDIR/fake-sender" -backend http://localhost:8080 -file "$FIXTURE" -title "verify" \
  >"$LOGDIR/sender.log" 2>&1 &
FAKE_PID=$!

# Wait for "tunnel open" to appear in log.
for i in $(seq 1 50); do
  if grep -q "tunnel open" "$LOGDIR/sender.log" 2>/dev/null; then break; fi
  sleep 0.2
  [[ $i == 50 ]] && fail "fake-sender tunnel did not open — see $LOGDIR/sender.log"
done

SHARE_URL=$(grep "share url:" "$LOGDIR/sender.log" | awk '{print $3}')
TOKEN="${SHARE_URL##*/s/}"
[[ -n "$TOKEN" ]] || fail "could not parse share token — see $LOGDIR/sender.log"
log "share token: ${TOKEN:0:16}…"

# -- 7. receiver: request + poll + download -------------------------------
log "receiver: requesting access"
REQ=$(curl -fsS -X POST "http://localhost:8080/v1/shares/by-token/$TOKEN/requests")
SESSION_ID=$(echo "$REQ" | jq -r .session_id)
[[ -n "$SESSION_ID" && "$SESSION_ID" != "null" ]] || fail "no session id in response: $REQ"

log "receiver: polling for approval"
for i in $(seq 1 50); do
  STATUS=$(curl -fsS "http://localhost:8080/v1/sessions/$SESSION_ID/status" | jq -r .status)
  [[ "$STATUS" == "approved" ]] && break
  sleep 0.2
  [[ $i == 50 ]] && fail "session not approved in 10s (auto-approver stuck)"
done

log "receiver: downloading /p/$SESSION_ID/files/$(basename "$FIXTURE")"
DOWNLOADED="$LOGDIR/downloaded.bin"
curl -fsS "http://localhost:8080/p/$SESSION_ID/files/$(basename "$FIXTURE")" -o "$DOWNLOADED"

# -- 8. integrity check ----------------------------------------------------
DL_SHA=$(shasum -a 256 "$DOWNLOADED" | awk '{print $1}')
if [[ "$FIXTURE_SHA" != "$DL_SHA" ]]; then
  fail "sha mismatch: expected $FIXTURE_SHA got $DL_SHA"
fi

log "✓ end-to-end transfer verified (sha256 $FIXTURE_SHA)"
log "logs: $LOGDIR"
