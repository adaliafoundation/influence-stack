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
printf '\nEDGE_MODE=external\nEDGE_NETWORK=existing-proxy\n' >> "$ENV_FILE"
load_env
compose_files
compose --profile indexer --profile auditor --profile tools config --format json > "$TEST_ROOT/server.json"
jq -e '
  (.services | has("caddy") | not) and
  (.services | has("influence-client") | not) and
  (.networks.edge.name == "existing-proxy") and .networks.edge.external and
  (.services["influence-server"].networks.edge.aliases == ["influence-production-api"]) and
  (.services.juno.networks.edge.aliases == ["influence-production-juno"]) and
  ([.services.mongo, .services.redis, .services.elasticsearch] | all(.networks | keys == ["data"]))
' "$TEST_ROOT/server.json" >/dev/null
export ENABLE_CLIENT=1
compose_files
compose config --format json > "$TEST_ROOT/client.json"
jq -e '(.services | has("caddy") | not) and
  (.services["influence-client"].networks.edge.aliases == ["influence-production-client"])' \
  "$TEST_ROOT/client.json" >/dev/null
export INTEGRATION_SECRETS_DIR="$TEST_ROOT"
compose -p isolated-test -f "$TEST_ROOT/compose.smoke.yaml" --profile tools \
  config --format json > "$TEST_ROOT/smoke.json"
jq -e '(.networks.edge.external != true) and (.networks.edge.name == "isolated-test_edge")' \
  "$TEST_ROOT/smoke.json" >/dev/null
echo 'External proxy routing, private data stores, and integration network isolation passed'
