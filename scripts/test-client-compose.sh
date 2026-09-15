#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
cp "$REPO_ROOT"/compose*.yaml "$TEST_ROOT/"
cp "$REPO_ROOT/.env.example" "$TEST_ROOT/.env"
cp "$REPO_ROOT/config/client.env.example" "$TEST_ROOT/client.env"
docker compose --project-directory "$TEST_ROOT" -f "$TEST_ROOT/compose.yaml" \
  -f "$TEST_ROOT/compose.client.yaml" config --format json > "$TEST_ROOT/rendered.json"
jq -e '
  .services["influence-client"] as $client |
  ($client.environment.REACT_APP_CONFIG_ENV == "production") and
  ($client.environment.REACT_APP_API_INFLUENCE == "https://api.example.com") and
  ($client.image | contains("@sha256:c23cbd73637726afc6b20b3704a32c78546feded325d2fde542a39f58110d4d4")) and
  (($client.ports // []) | length == 0) and
  (($client.secrets // []) | length == 0) and
  ($client.read_only == true) and
  (.services.caddy.depends_on["influence-client"].condition == "service_healthy") and
  (.services.caddy.depends_on["influence-server"].condition == "service_healthy") and
  ([.services.caddy.volumes[].target] | index("/etc/caddy/Caddyfile") != null) and
  ([.services.caddy.volumes[].target] | index("/etc/caddy/client/site.caddy") != null)
' "$TEST_ROOT/rendered.json" >/dev/null
echo 'Client mainnet configuration, isolation, and edge dependency checks passed'
