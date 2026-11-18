#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
STACK_ROOT="$TEST_ROOT"
ENV_FILE="$TEST_ROOT/.env"
cp "$REPO_ROOT"/compose*.yaml "$TEST_ROOT/"
cp "$REPO_ROOT/.env.example" "$ENV_FILE"
cp "$REPO_ROOT/config/client.env.example" "$TEST_ROOT/client.env"
load_env
compose_files
compose config --format json > "$TEST_ROOT/disabled.json"
jq -e '(.services | has("influence-private-data") | not)' "$TEST_ROOT/disabled.json" >/dev/null
export ENABLE_PRIVATE_DATA=1 PRIVATE_DATA_DOMAIN=private-data.test.invalid
compose_files
compose config --format json > "$TEST_ROOT/peer.json"
jq -e '
  .services["influence-private-data"] as $peer |
  ($peer.image == .services["influence-server"].image) and
  ($peer.command == ["node", "src/workers/privateData.mjs"]) and
  (($peer.secrets // []) | length == 0) and
  (($peer.depends_on // {}) | length == 0) and
  (($peer.ports // []) | length == 0) and
  ($peer.networks | keys | sort == ["edge", "outbound"]) and
  ($peer.read_only == true) and ($peer.cap_drop == ["ALL"]) and
  ($peer.environment.PRIVATE_DATA_DIRECTORY == "/data/private-records") and
  ($peer.environment.PRIVATE_DATA_ANNOUNCE == "/dns4/private-data.test.invalid/tcp/443/wss") and
  ($peer.environment | has("MONGO_URL_FILE") | not) and
  ($peer.volumes[0].target == "/data/private-records") and
  (.services.caddy.depends_on["influence-private-data"].condition == "service_healthy") and
  ([.services.caddy.volumes[].target] | index("/etc/caddy/private-data/site.caddy") != null)
' "$TEST_ROOT/peer.json" >/dev/null
export INTEGRATION_SECRETS_DIR="$TEST_ROOT"
compose -p isolated-private-data -f "$TEST_ROOT/compose.smoke.yaml" config --format json > "$TEST_ROOT/smoke.json"
jq -e '
  .services["influence-private-data"] as $peer |
  (($peer.volumes // []) | length == 0) and
  ($peer.tmpfs | any(startswith("/data/private-records:"))) and
  (.networks.edge.external != true)
' "$TEST_ROOT/smoke.json" >/dev/null
# External proxies get the same peer on a project-specific network alias.
export EDGE_MODE=external EDGE_NETWORK=shared-proxy
compose_files
compose config --format json > "$TEST_ROOT/external.json"
jq -e '(.services | has("caddy") | not) and
  (.services["influence-private-data"].networks.edge.aliases == ["influence-production-private-data"])' \
  "$TEST_ROOT/external.json" >/dev/null
echo 'Private-data image pin, persistent volume, isolation, WSS proxy, and disposable smoke storage passed'
