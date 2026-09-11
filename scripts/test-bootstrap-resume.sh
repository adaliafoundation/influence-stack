#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
STATE_DIR="$TEST_ROOT/state"
DATA_ROOT="$TEST_ROOT/data"
mkdir -p "$STATE_DIR" "$DATA_ROOT/juno-data" "$DATA_ROOT/backups"
require_command() { :; }
load_env() { :; }
refresh_connection_secrets() { :; }
validate_configuration() { :; }
compose_files() { :; }
validate_application_images() { :; }
require_integration_test() { :; }
install_juno_snapshot() { :; }
compose() { :; }
wait_for_health() { :; }
restore_mongo() { echo restore >> "$TEST_ROOT/actions"; }
mongo_metrics() { printf '%s\n' "${METRICS:-{\"ethereumCheckpoint\":1,\"starknetCheckpoint\":2,\"entities\":10,\"packedLotCacheEntries\":1}}"; }
wait_for_juno() { :; }
juno_block() { echo 3; }
juno_has_block() { [ "$1" = 2 ]; }
# Stop at the first downstream action; only bootstrap dispatch is under test.
reset_elasticsearch() { echo index >> "$TEST_ROOT/actions"; exit 0; }
(bootstrap_stack --resume-after-restore)
[ "$(cat "$TEST_ROOT/actions")" = index ]
: > "$TEST_ROOT/actions"
(bootstrap_stack --mongo-dump fixture.archive)
[ "$(cat "$TEST_ROOT/actions")" = "$(printf 'restore\nindex')" ]
expect_failure() {
  local status
  : > "$TEST_ROOT/actions"
  set +e
  (set -e; bootstrap_stack "$@") > "$TEST_ROOT/error" 2>&1
  status="$?"
  set -e
  [ "$status" -ne 0 ]
  [ ! -s "$TEST_ROOT/actions" ]
}
expect_failure --resume-after-restore --mongo-dump fixture.archive
METRICS='{"ethereumCheckpoint":1,"starknetCheckpoint":2,"entities":0,"packedLotCacheEntries":0}' expect_failure --resume-after-restore
: > "$STATE_DIR/bootstrap-complete"
expect_failure --resume-after-restore
echo 'Bootstrap resume, restore, and validation checks passed'
