#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
JUNO_SNAPSHOT_EXPECTED_VERSION=v0.16.6
JUNO_SNAPSHOT_EXTRACTION_RESERVE_GB=0
JUNO_SNAPSHOT_SHA256=

juno_snapshot_headers() {
  local suffix=''
  [ "$JUNO_SNAPSHOT_KIND" != pruned ] || suffix='_pruned'
  printf '4\ncontent-disposition: attachment; filename=juno_%s%s_v0.16.6.tar.zst\n' \
    "$JUNO_NETWORK" "$suffix"
}
download_juno_snapshot() {
  [ "$1" = "$DATA_ROOT/downloads/juno-$JUNO_NETWORK.tar.zst.part" ]
  printf data > "$1"
}
# Model the upstream archive layouts while exercising actual staging and file moves.
tar() {
  local destination="$5"
  [ "$4" = -C ]
  if [ -n "$WRAPPER" ]; then destination="$destination/$WRAPPER"; fi
  mkdir -p "$destination"
  printf database > "$destination/CURRENT"
}

for JUNO_NETWORK in mainnet sepolia; do
  for JUNO_SNAPSHOT_KIND in full pruned; do
    WRAPPER="juno_$JUNO_NETWORK"
    [ "$JUNO_SNAPSHOT_KIND" != pruned ] || WRAPPER="${WRAPPER}_pruned"
    for layout in wrapped flat; do
      [ "$layout" != flat ] || WRAPPER=''
      DATA_ROOT="$TEST_ROOT/$JUNO_NETWORK-$JUNO_SNAPSHOT_KIND-$layout"
      JUNO_SNAPSHOT_URL="https://snapshot.invalid/$JUNO_NETWORK/$JUNO_SNAPSHOT_KIND"
      mkdir -p "$DATA_ROOT/juno-data" "$DATA_ROOT/downloads"
      install_juno_snapshot
      [ "$(cat "$DATA_ROOT/juno-data/CURRENT")" = database ]
      [ -z "$(find "$DATA_ROOT/downloads" -type f -print -quit)" ]
      # Existing node data must be reused without touching the downloader.
      (download_juno_snapshot() { exit 1; }; install_juno_snapshot)
    done
  done
done
echo 'Mainnet and Sepolia snapshot staging, layouts, and existing-data reuse passed'
