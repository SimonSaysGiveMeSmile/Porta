#!/usr/bin/env bash
# scripts/tunnel-ngrok.sh
#
# Same idea as tunnel-cloudflare.sh but via ngrok. Requires a free ngrok
# account + authtoken (ngrok config add-authtoken <token>).
#
#   brew install ngrok/ngrok/ngrok
#   ./scripts/tunnel-ngrok.sh          # tunnels :8080
#   ./scripts/tunnel-ngrok.sh 9090     # tunnels :9090

set -euo pipefail

PORT="${1:-8080}"

command -v ngrok >/dev/null || {
  echo "ngrok not installed. Run:"
  echo "  brew install ngrok/ngrok/ngrok"
  echo "  ngrok config add-authtoken <your-token>"
  exit 1
}

echo "Starting ngrok tunnel → http://localhost:$PORT"
echo "Note the 'Forwarding' URL, then set PORTA_PUBLIC_BASE_URL to it."
echo

exec ngrok http "$PORT" --log=stdout
