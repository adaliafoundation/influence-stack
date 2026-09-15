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
expect_failure --resume-after-indexing --mongo-dump fixture.archive
expect_failure --resume-after-indexing --resume-after-restore
expect_failure --resume-after-indexing --rebuild-packed-cache
METRICS='{"ethereumCheckpoint":1,"starknetCheckpoint":2,"entities":10,"packedLotCacheEntries":0}' expect_failure --resume-after-indexing

# Verify resume preserves data and only completes after all health gates pass.
install_juno_snapshot() { echo snapshot >> "$TEST_ROOT/actions"; }
compose() { echo "compose $*" >> "$TEST_ROOT/actions"; }
validate_existing_search() { echo search-check >> "$TEST_ROOT/actions"; }
wait_for_convergence() { echo convergence >> "$TEST_ROOT/actions"; }
wait_for_required_workers() { echo worker-health >> "$TEST_ROOT/actions"; }
wait_for_health() { echo "health $1" >> "$TEST_ROOT/actions"; }
: > "$TEST_ROOT/actions"
(bootstrap_stack --resume-after-indexing)
[ -s "$STATE_DIR/bootstrap-complete" ]
! grep -Eq '^(restore|index|snapshot)$|initialSetup|reIndex|preloadLotData' "$TEST_ROOT/actions"
grep -q '^search-check$' "$TEST_ROOT/actions"
grep -q '^health influence-server$' "$TEST_ROOT/actions"
rm "$STATE_DIR/bootstrap-complete"
wait_for_convergence() { return 1; }
: > "$TEST_ROOT/actions"
set +e
(set -e; bootstrap_stack --resume-after-indexing) > "$TEST_ROOT/error" 2>&1
status="$?"
set -e
[ "$status" -ne 0 ]
[ ! -e "$STATE_DIR/bootstrap-complete" ]
! grep -q '^health influence-server$' "$TEST_ROOT/actions"
validate_existing_search() { return 1; }
: > "$TEST_ROOT/actions"
set +e
(set -e; bootstrap_stack --resume-after-indexing) > "$TEST_ROOT/error" 2>&1
status="$?"
set -e
[ "$status" -ne 0 ]
[ ! -e "$STATE_DIR/bootstrap-complete" ]
! grep -q 'up -d influence-indexer' "$TEST_ROOT/actions"
: > "$STATE_DIR/bootstrap-complete"
expect_failure --resume-after-restore
expect_failure --resume-after-indexing
echo 'Bootstrap resume, restore, and validation checks passed'
