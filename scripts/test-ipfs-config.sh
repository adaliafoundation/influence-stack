#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
STACK_ROOT="$TEST_ROOT"
ENV_FILE="$TEST_ROOT/.env"
STATE_DIR="$TEST_ROOT/.state"
cp "$REPO_ROOT/.env.example" "$TEST_ROOT/"
cp "$REPO_ROOT"/compose*.yaml "$TEST_ROOT/"
init_stack
load_env
[ -f "$TEST_ROOT/secrets/ipfs_rpc_authorization" ]
[ ! -s "$TEST_ROOT/secrets/ipfs_rpc_authorization" ]
[ -z "${IPFS_RPC_AUTHORIZATION_FILE:-}" ]
compose_files
compose config --format json > "$TEST_ROOT/render.json"
jq -e '.services["influence-server"].environment |
  .IPFS_RPC_URL == "" and .IPFS_GATEWAY_URL == "" and
  .IPFS_RPC_AUTHORIZATION_FILE == null' "$TEST_ROOT/render.json" >/dev/null
printf 'Bearer test-only-token\n' > "$TEST_ROOT/header"
install_secret ipfs_rpc_authorization "$TEST_ROOT/header"
[ "$(file_permissions "$TEST_ROOT/secrets/ipfs_rpc_authorization")" = 600 ]
printf '\nIPFS_RPC_URL=https://rpc.invalid/api/v0\nIPFS_GATEWAY_URL=https://gateway.invalid\n' >> "$ENV_FILE"
load_env
compose config --format json > "$TEST_ROOT/render.json"
jq -e '.services["influence-server"] |
  .environment.IPFS_RPC_URL == "https://rpc.invalid/api/v0" and
  .environment.IPFS_GATEWAY_URL == "https://gateway.invalid" and
  .environment.IPFS_RPC_AUTHORIZATION_FILE == "/run/secrets/ipfs_rpc_authorization" and
  (.secrets | any(.source == "ipfs_rpc_authorization")) and
  (.environment | has("IPFS_RPC_AUTHORIZATION") | not)' "$TEST_ROOT/render.json" >/dev/null
if grep -qE 'test-only-token|IPFS_INFURA|ipfs_infura' "$TEST_ROOT/render.json"; then
  echo 'Obsolete IPFS configuration or secret content leaked into Compose' >&2
  exit 1
fi
printf 'IPFS configuration and secret mount checks passed\n'
