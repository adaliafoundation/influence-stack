#!/usr/bin/env bash
# Mocks run inside backup_stack's subshell and read its dynamically scoped output.
# shellcheck disable=SC2031
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
STACK_ROOT="$TEST_ROOT"
ENV_FILE="$TEST_ROOT/.env"
STATE_DIR="$TEST_ROOT/.state"
mkdir -p "$STATE_DIR" "$TEST_ROOT/secrets" "$TEST_ROOT/data/backups"
cp "$REPO_ROOT/.env.example" "$ENV_FILE"
printf '\nDATA_ROOT=%s/data\n' "$TEST_ROOT" >> "$ENV_FILE"
printf 'test-only-password\n' > "$TEST_ROOT/secrets/restic_password"
chmod 600 "$TEST_ROOT/secrets/restic_password"
require_command() { :; }
flock() { return "${LOCK_FAILURE:-0}"; }
compose() {
  case "$*" in
    'ps -q influence-server') echo running ;;
    ps*) ;;
    *' unpause '*) echo unpause >> "$TEST_ROOT/events" ;;
    *' pause '*) echo pause >> "$TEST_ROOT/events" ;;
    *' run '*)
      echo dump >> "$TEST_ROOT/events"
      printf 'test database\n' > "$output"
      return "${DUMP_FAILURE:-0}"
      ;;
    *) echo "Unexpected compose: $*" >&2; return 1 ;;
  esac
}
restic() {
  local args=" $* "
  if [[ "$args" == *' snapshots '* ]]; then
    echo preflight >> "$TEST_ROOT/events"
    return "${REMOTE_FAILURE:-0}"
  elif [[ "$args" == *' backup '* ]]; then
    echo upload >> "$TEST_ROOT/events"
    [ "$(tail -n 2 "$TEST_ROOT/events" | head -n 1)" = unpause ]
    [[ "$args" == *" --exclude $TEST_ROOT/secrets/restic_password "* ]]
    [ -s "$output" ]
    return "${UPLOAD_FAILURE:-0}"
  elif [[ "$args" == *' forget '* ]]; then
    echo retention >> "$TEST_ROOT/events"
    [ ! -e "$output" ]
    [[ "$args" == *' --group-by host,tags '* ]]
    return "${RETENTION_FAILURE:-0}"
  else
    echo "Unexpected restic: $*" >&2
    return 1
  fi
}
run_failure() {
  local status
  set +e
  ( set -e; backup_stack ) > "$TEST_ROOT/error" 2>&1
  status="$?"
  set -e
  [ "$status" -ne 0 ] || { echo 'Expected backup to fail' >&2; exit 1; }
}
backup_stack
[ "$(cat "$TEST_ROOT/events")" = "$(printf 'preflight\npause\ndump\nunpause\nupload\nretention')" ]
[ -z "$(find "$TEST_ROOT/data/backups" -type f)" ]
: > "$TEST_ROOT/events"
REMOTE_FAILURE=1 run_failure
[ "$(cat "$TEST_ROOT/events")" = preflight ]
: > "$TEST_ROOT/events"
UPLOAD_FAILURE=1 run_failure
[ "$(tail -n 1 "$TEST_ROOT/events")" = upload ]
[ -n "$(find "$TEST_ROOT/data/backups" -name influence.archive)" ]
: > "$TEST_ROOT/events"
DUMP_FAILURE=1 run_failure
[ "$(tail -n 1 "$TEST_ROOT/events")" = unpause ]
if grep -q upload "$TEST_ROOT/events"; then exit 1; fi
: > "$TEST_ROOT/events"
RETENTION_FAILURE=1 run_failure
[ "$(tail -n 1 "$TEST_ROOT/events")" = retention ]
: > "$TEST_ROOT/events"
LOCK_FAILURE=1 run_failure
[ ! -s "$TEST_ROOT/events" ]
printf 'Backup success and failure checks passed\n'
