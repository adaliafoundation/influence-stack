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

render() {
  docker compose --env-file "$ENV_FILE" -f "$TEST_ROOT/compose.yaml" \
    -f "$TEST_ROOT/compose.client.yaml" --profile indexer --profile auditor \
    --profile tools config --format json
}

check_environment() {
  local environment="$1" network="$2"
  render > "$TEST_ROOT/rendered.json"
  jq -e --arg environment "$environment" --arg network "$network" '
    ([.services | to_entries[] |
      select(.key | startswith("influence-")) | select(.key != "influence-client") |
      .value.environment] | length == 8 and all(
        .NODE_ENV == $environment and .HEALTH_NAMESPACE == $environment
        and .STARKNET_RPC_PROVIDER == "http://juno:6060/v0_8"))
    and (.services["influence-client"].environment.NODE_ENV == "production")
    and (.services["influence-client"].environment.REACT_APP_CONFIG_ENV == $environment)
    and (.services.juno.command[1] == $network)
    and (.services.juno.labels["com.influenceth.stack.environment"] == $environment)
    and (.services["influence-server"].labels["com.influenceth.stack.environment"] == $environment)
  ' "$TEST_ROOT/rendered.json" >/dev/null
  docker compose --env-file "$ENV_FILE" -f "$TEST_ROOT/compose.juno.yaml" \
    config --format json > "$TEST_ROOT/juno.json"
  jq -e --slurpfile full "$TEST_ROOT/rendered.json" \
    '.services.juno == $full[0].services.juno' "$TEST_ROOT/juno.json" >/dev/null
}

# A pre-existing production .env need not gain any new settings.
sed '/^STACK_ENVIRONMENT=/d; /^JUNO_NETWORK=/d; /^HEALTH_NAMESPACE=/d' \
  "$ENV_FILE" > "$TEST_ROOT/legacy.env"
mv "$TEST_ROOT/legacy.env" "$ENV_FILE"
check_environment production mainnet
validate_environment

cat >> "$ENV_FILE" <<'EOF'
STACK_ENVIRONMENT=prerelease
JUNO_NETWORK=sepolia
JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/sepolia/latest
JUNO_SNAPSHOT_KIND=full
COMPOSE_PROJECT_NAME=influence-prerelease
DATA_ROOT=/influence-prerelease-data
EOF
(load_env; check_environment prerelease sepolia)
# Compose's explicit environment must override a conflicting client env_file.
printf '\nREACT_APP_CONFIG_ENV=production\n' >> "$TEST_ROOT/client.env"
(load_env; check_environment prerelease sepolia)

expect_invalid() {
  if (validate_environment) > "$TEST_ROOT/error" 2>&1; then
    echo 'Expected environment validation failure' >&2
    exit 1
  fi
  grep -q "$1" "$TEST_ROOT/error"
}
STACK_ENVIRONMENT=prerelease JUNO_NETWORK=mainnet expect_invalid STACK_ENVIRONMENT
STACK_ENVIRONMENT=production JUNO_NETWORK=sepolia expect_invalid STACK_ENVIRONMENT
STACK_ENVIRONMENT=typo JUNO_NETWORK=mainnet expect_invalid STACK_ENVIRONMENT
STACK_ENVIRONMENT=prerelease JUNO_NETWORK=sepolia \
  JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/mainnet-pruned/latest \
  expect_invalid JUNO_SNAPSHOT_URL
STACK_ENVIRONMENT=production JUNO_NETWORK=mainnet \
  JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/sepolia/latest \
  expect_invalid JUNO_SNAPSHOT_URL

echo 'Production defaults, prerelease roles, standalone Juno, and network validation passed'
