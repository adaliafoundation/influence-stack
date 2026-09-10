#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# Load the command functions without dispatching the CLI.
# shellcheck source=stack
source "$REPO_ROOT/stack"
STACK_ROOT="$TEST_ROOT"
ENV_FILE="$TEST_ROOT/.env"
STATE_DIR="$TEST_ROOT/.state"
mkdir -p "$STATE_DIR" "$TEST_ROOT/secrets" "$TEST_ROOT/data/juno-data" "$TEST_ROOT/data/downloads"
cp "$REPO_ROOT/.env.example" "$ENV_FILE"
printf '\nDATA_ROOT=%s/data\n' "$TEST_ROOT" >> "$ENV_FILE"
printf 'wss://validation.invalid\n' > "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
chmod 600 "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
printf 'existing database\n' > "$TEST_ROOT/data/juno-data/CURRENT"

require_command() { :; }
# Exercise the real existing-data branch: any download would fail this test.
curl() { echo 'Unexpected download' >&2; return 1; }
compose() {
  [ "${COMPOSE_ARGS[3]}" = "$STACK_ROOT/compose.juno.yaml" ]
  case "$*" in
    'config --quiet'|'up -d --no-deps juno') printf '%s\n' "$*" >> "$TEST_ROOT/calls" ;;
    *) echo "Unexpected Compose action: $*" >&2; return 1 ;;
  esac
}
wait_for_juno() { printf 'ready\n' >> "$TEST_ROOT/calls"; }

prepare_juno
prepare_juno
[ "$(wc -l < "$TEST_ROOT/calls" | tr -d ' ')" = 6 ]
[ -f "$TEST_ROOT/data/juno-data/CURRENT" ]
[ ! -e "$STATE_DIR/bootstrap-complete" ]

expect_failure() {
  local expected="$1"
  shift
  if ( "$@" ) > "$TEST_ROOT/error" 2>&1; then
    echo "Expected failure: $expected" >&2
    exit 1
  fi
  grep -q "$expected" "$TEST_ROOT/error"
}

expect_failure 'Usage:' prepare_juno unexpected
chmod 644 "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
expect_failure 'owner-only' prepare_juno
chmod 600 "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
printf 'https://validation.invalid\n' > "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
expect_failure 'wss://' prepare_juno
printf 'wss://validation.invalid\n' > "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
printf '\nJUNO_SNAPSHOT_EXPECTED_VERSION=v0.0.1\n' >> "$ENV_FILE"
expect_failure 'same release' prepare_juno
printf '\nJUNO_SNAPSHOT_EXPECTED_VERSION=v0.16.6\n' >> "$ENV_FILE"
: > "$STATE_DIR/bootstrap-complete"
expect_failure 'already bootstrapped' prepare_juno
printf 'Juno preparation command checks passed\n'
