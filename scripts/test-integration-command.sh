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
INTEGRATION_RECEIPT="$STATE_DIR/server-integration-test"
mkdir -p "$TEST_ROOT/scripts"
cp "$REPO_ROOT/scripts/check-client-image.js" "$TEST_ROOT/scripts/"
cp "$REPO_ROOT/.env.example" "$ENV_FILE"
configured="server@sha256:$(printf '%064d' 1)"
candidate="server@sha256:$(printf '%064d' 2)"
printf '\nINFLUENCE_SERVER_IMAGE=%s\n' "$configured" >> "$ENV_FILE"

require_command() { :; }
validate_application_images() { :; }
deployment_fingerprint() { printf '%s:%s:%s' "$INFLUENCE_SERVER_IMAGE" "${ENABLE_CLIENT:-0}" "${INFLUENCE_CLIENT_IMAGE:-}"; }
wait_for_health() {
  if [ "$1" = influence-client ] && [ "${FAIL_CLIENT_HEALTH:-0}" = 1 ]; then return 1; fi
}
compose() {
  case "$*" in
    '--profile tools run --rm --no-deps influence-tools -e '*)
      echo server-check >> "$TEST_ROOT/actions"
      [ "${FAIL_SERVER:-0}" != 1 ] ;;
    'exec -T influence-client node')
      cat > "$TEST_ROOT/client-probe"
      echo client-check >> "$TEST_ROOT/actions"
      [ "${FAIL_CLIENT:-0}" != 1 ] ;;
    *) printf '%s\n' "$*" >> "$TEST_ROOT/actions" ;;
  esac
}

(integration_test)
grep -q "^image=$configured$" "$INTEGRATION_RECEIPT"
if grep -q influence-client "$TEST_ROOT/actions"; then exit 1; fi
(load_env; require_integration_test)
(integration_test "$candidate")
grep -q "^image=$candidate$" "$INTEGRATION_RECEIPT"
grep -q "^INFLUENCE_SERVER_IMAGE=$configured$" "$ENV_FILE"

printf '\nENABLE_CLIENT=1\n' >> "$ENV_FILE"
: > "$TEST_ROOT/actions"
(integration_test)
grep -q '^pull influence-client$' "$TEST_ROOT/actions"
grep -q '^up -d --no-deps influence-client$' "$TEST_ROOT/actions"
grep -q '^client-check$' "$TEST_ROOT/actions"
cmp "$REPO_ROOT/scripts/check-client-image.js" "$TEST_ROOT/client-probe"
(load_env; require_integration_test)
# The real receipt check must reject changes to the client digest as well.
set +e
(set -e; load_env; INFLUENCE_CLIENT_IMAGE="$candidate"; require_integration_test) > "$TEST_ROOT/error" 2>&1
status="$?"
set -e
[ "$status" -ne 0 ]
grep -q 'configuration changed' "$TEST_ROOT/error"

expect_failure() {
  rm -f "$INTEGRATION_RECEIPT"
  : > "$TEST_ROOT/actions"
  set +e
  (set -e; integration_test "$@") > "$TEST_ROOT/error" 2>&1
  local status="$?"
  set -e
  [ "$status" -ne 0 ]
  [ ! -e "$INTEGRATION_RECEIPT" ]
}
FAIL_CLIENT=1 expect_failure
grep -q '^down --volumes --remove-orphans$' "$TEST_ROOT/actions"
FAIL_CLIENT_HEALTH=1 expect_failure
grep -q '^down --volumes --remove-orphans$' "$TEST_ROOT/actions"
FAIL_SERVER=1 expect_failure
grep -q '^down --volumes --remove-orphans$' "$TEST_ROOT/actions"
expect_failure one two
grep -q 'Usage:' "$TEST_ROOT/error"
expect_failure invalid-image
grep -q INFLUENCE_SERVER_IMAGE "$TEST_ROOT/error"
printf '\nINFLUENCE_CLIENT_IMAGE=client:mutable\n' >> "$ENV_FILE"
expect_failure
grep -q INFLUENCE_CLIENT_IMAGE "$TEST_ROOT/error"
[ ! -s "$TEST_ROOT/actions" ]
echo 'Configured and override digests, client checks, receipt gating, and cleanup passed'
