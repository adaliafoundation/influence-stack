#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
JUNO_SNAPSHOT_URL=https://snapshot.invalid/latest
calls=0
sleep() { :; }
curl() {
  [[ " $* " == *' --http1.1 '* ]]
  if [[ " $* " == *' -fsSIL '* ]]; then
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nContent-Disposition: attachment; filename=juno_pruned_v0.16.6.tar.zst\r\n'
    return
  fi
  [[ " $* " == *' --continue-at - '* ]]
  calls=$((calls + 1))
  local file="$TEST_ROOT/partial"
  if [ "$calls" -eq 1 ]; then
    printf abc >> "$file"
    return 92
  fi
  [ "$(cat "$file")" = abc ]
  printf def >> "$file"
}
headers="$(juno_snapshot_headers)"
[ "$headers" = $'6\ncontent-disposition: attachment; filename=juno_pruned_v0.16.6.tar.zst' ]
download_juno_snapshot "$TEST_ROOT/partial" "$headers"
[ "$calls" -eq 2 ]
[ "$(cat "$TEST_ROOT/partial")" = abcdef ]
curl() { calls=$((calls + 1)); return 23; }
calls=0
if download_juno_snapshot "$TEST_ROOT/partial" "$headers"; then exit 1; fi
[ "$calls" -eq 1 ]
juno_snapshot_headers() { printf '%s\n' "$headers"; }
curl() { calls=$((calls + 1)); return 56; }
calls=0
if download_juno_snapshot "$TEST_ROOT/partial" "$headers"; then exit 1; fi
[ "$calls" -eq 6 ]
juno_snapshot_headers() { echo changed; }
if (download_juno_snapshot "$TEST_ROOT/partial" "$headers") > "$TEST_ROOT/error" 2>&1; then exit 1; fi
grep -q 'metadata changed' "$TEST_ROOT/error"
printf 'Snapshot resume, retry limit, header parsing, and identity checks passed\n'
