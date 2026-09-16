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
INTEGRATION_RECEIPT="$STATE_DIR/receipt"
original="ghcr.io/adaliafoundation/influence-server@sha256:$(printf '%064d' 1)"
server_digest="sha256:$(printf '%064d' 2)"
client_digest="sha256:$(printf '%064d' 3)"
reset_fixture() {
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR" "$STACK_ROOT/secrets"
  echo ready > "$STATE_DIR/bootstrap-complete"
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  cat >> "$ENV_FILE" <<EOF
STACK_ENVIRONMENT=prerelease
JUNO_NETWORK=sepolia
JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/sepolia/latest
ENABLE_PRERELEASE_UPDATES=1
ENABLE_CLIENT=1
INFLUENCE_SERVER_IMAGE=$original
EOF
  : > "$TEST_ROOT/actions"
}
require_command() { :; }
flock() { :; }
validate_configuration() { :; }
ensure_juno_image_applied() { :; }
deployment_fingerprint() { printf '%s:%s' "$INFLUENCE_SERVER_IMAGE" "$INFLUENCE_CLIENT_IMAGE"; }
docker() {
  [[ "$*" == 'buildx imagetools inspect '* ]]
  if [[ "$4" == *influence-server:* ]]; then echo "$server_digest"; else echo "$client_digest"; fi
}
integration_test() {
  [ "$ENV_FILE" != "$TEST_ROOT/.env" ]
  load_env
  echo integration >> "$TEST_ROOT/actions"
  [ "${FAIL_STAGE:-}" != integration ] || return 1
  record_integration_test "$INFLUENCE_SERVER_IMAGE" "$(deployment_fingerprint)"
}
backup_stack() {
  grep -q "^INFLUENCE_SERVER_IMAGE=$original$" "$ENV_FILE"
  echo backup >> "$TEST_ROOT/actions"
  [ "${FAIL_STAGE:-}" != backup ]
}
compose() {
  echo "compose $*" >> "$TEST_ROOT/actions"
  [ "${FAIL_STAGE:-}" != deploy ]
}
wait_for_required_application_health() {
  echo health >> "$TEST_ROOT/actions"
  [ "${FAIL_STAGE:-}" != health ]
}
expect_failure() {
  set +e
  (set -e; prerelease_update) > "$TEST_ROOT/error" 2>&1
  local status="$?"
  set -e
  [ "$status" -ne 0 ]
}
reset_fixture
prerelease_update
[ ! -e "$STATE_DIR/prerelease-update-failed" ]
grep -q "^INFLUENCE_SERVER_IMAGE=ghcr.io/adaliafoundation/influence-server@$server_digest$" "$ENV_FILE"
grep -q "^INFLUENCE_CLIENT_IMAGE=ghcr.io/adaliafoundation/influence-client@$client_digest$" "$ENV_FILE"
grep -q "^INFLUENCE_SERVER_IMAGE=$original$" "$STATE_DIR/prerelease-previous.env"
[ "$(head -n 2 "$TEST_ROOT/actions")" = "$(printf 'integration\nbackup')" ]
grep -q '^compose .*up -d --no-deps influence-server' "$TEST_ROOT/actions"
if grep '^compose ' "$TEST_ROOT/actions" | grep -Eq ' (juno|mongo|redis|elasticsearch|caddy)( |$)'; then exit 1; fi
: > "$TEST_ROOT/actions"
prerelease_update
[ ! -s "$TEST_ROOT/actions" ]

# A queued notification must reread pins changed by the previous lock holder.
reset_fixture
flock() {
  replace_env_value INFLUENCE_SERVER_IMAGE "ghcr.io/adaliafoundation/influence-server@$server_digest"
  replace_env_value INFLUENCE_CLIENT_IMAGE "ghcr.io/adaliafoundation/influence-client@$client_digest"
}
prerelease_update
[ ! -s "$TEST_ROOT/actions" ]
flock() { :; }

for stage in integration backup deploy health; do
  reset_fixture
  FAIL_STAGE="$stage" expect_failure
  [ -s "$STATE_DIR/prerelease-update-failed" ]
  if [[ "$stage" = integration || "$stage" = backup ]]; then
    grep -q "^INFLUENCE_SERVER_IMAGE=$original$" "$ENV_FILE"
    [ ! -e "$INTEGRATION_RECEIPT" ]
  fi
  : > "$TEST_ROOT/actions"
  expect_failure
  [ ! -s "$TEST_ROOT/actions" ]
done
reset_fixture
printf '\nSTACK_ENVIRONMENT=production\nJUNO_NETWORK=mainnet\nJUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/mainnet/latest\n' >> "$ENV_FILE"
expect_failure
grep -q prerelease-only "$TEST_ROOT/error"
[ ! -s "$TEST_ROOT/actions" ]
reset_fixture
printf '\nENABLE_PRERELEASE_UPDATES=0\n' >> "$ENV_FILE"
prerelease_update
[ ! -s "$TEST_ROOT/actions" ]

printf 'fixture-token-rn\n' > "$STACK_ROOT/secrets/prerelease_webhook_token"
chmod 600 "$STACK_ROOT/secrets/prerelease_webhook_token"
configure_prerelease_webhook
jq -e '.[0] | (."http-methods" == ["POST"]) and
  (."trigger-rule".match.value == "fixture-token-rn") and
  (."trigger-rule-mismatch-http-response-code" == 403) and
  (."pass-arguments-to-command" == [{source:"string",name:"prerelease-update"}])' \
  "$STATE_DIR/prerelease-hooks.json" >/dev/null
[ "$(file_permissions "$STATE_DIR/prerelease-hooks.json")" = 600 ]
echo 'Prerelease sequencing, no-op, failure blocking, production guard, and webhook authentication passed'
