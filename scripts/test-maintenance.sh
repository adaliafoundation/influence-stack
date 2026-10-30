#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker run --rm \
  -e API_DOMAIN=http://localhost:8080 -e CADDY_EMAIL=test@example.com \
  -v "$REPO_ROOT/config/Caddyfile:/etc/caddy/Caddyfile:ro" \
  caddy:2.11.4-alpine sh -ec '
    mkdir -p /srv/maintenance
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/tmp/caddy.log 2>&1 &
    trap "kill $!" EXIT
    ready=0
    for attempt in 1 2 3 4 5; do
      if wget -qO /tmp/status http://localhost:8080/maintenance; then ready=1; break; fi
      sleep 1
    done
    [ "$ready" = 1 ] || { cat /tmp/caddy.log; exit 1; }
    grep -Fxq '\''{"active":false}'\'' /tmp/status
    printf '\''{"active":true,"reason":"backup","startedAt":"2026-10-30T07:00:00Z"}\n'\'' > /srv/maintenance/status.json
    wget -SO /tmp/status http://localhost:8080/maintenance 2>/tmp/headers
    cmp /srv/maintenance/status.json /tmp/status
    grep -iq "Cache-Control: no-store" /tmp/headers
    grep -iq "Access-Control-Allow-Origin: \\*" /tmp/headers
    rm /srv/maintenance/status.json
    wget -qO /tmp/status http://localhost:8080/maintenance
    grep -Fxq '\''{"active":false}'\'' /tmp/status
    echo "Maintenance endpoint lifecycle passed with no API server"
  '
