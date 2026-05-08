#!/usr/bin/env bash
# scripts/tunnel-cloudflare.sh
#
# Exposes the local backend to the internet via a Cloudflare Quick Tunnel.
# No Cloudflare account, no DNS setup — just `cloudflared` installed.
#
#   brew install cloudflare/cloudflare/cloudflared
#   ./scripts/tunnel-cloudflare.sh           # tunnels :8080
#   ./scripts/tunnel-cloudflare.sh 9090      # tunnels :9090
#
# Quick tunnels get a random *.trycloudflare.com URL that stays alive until
# you Ctrl-C. Use the printed URL as PORTA_PUBLIC_BASE_URL when running the
# backend so share links point at the tunneled hostname.

set -euo pipefail

PORT="${1:-8080}"

command -v cloudflared >/dev/null || {
  echo "cloudflared not installed. Run:"
  echo "  brew install cloudflare/cloudflare/cloudflared"
  exit 1
}

echo "Starting Cloudflare quick tunnel → http://localhost:$PORT"
echo "Look for 'https://<name>.trycloudflare.com' in the output below."
echo "Set PORTA_PUBLIC_BASE_URL to that URL before restarting the backend"
echo "so generated share links use the public hostname."
echo

exec cloudflared tunnel --url "http://localhost:$PORT" --no-autoupdate
