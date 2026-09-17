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
mkdir "$TEST_ROOT/secrets"
load_env
compose_files
compose config --format json > "$TEST_ROOT/render.json"
jq -e '.services | has("influence-notifications") | not' "$TEST_ROOT/render.json" >/dev/null
validate_notifications
NOTIFICATIONS_EMAIL_ENABLED=1
if (validate_notifications) >/dev/null 2>&1; then
  echo 'Missing notification settings accepted' >&2
  exit 1
fi
NOTIFICATIONS_EMAIL_FROM_EMAIL=sender@example.com
SENDGRID_TEMPLATE_NOTIFICATION=d-fixture
printf 'fixture-key' > "$TEST_ROOT/secrets/sendgrid_api_key"
chmod 600 "$TEST_ROOT/secrets/sendgrid_api_key"
validate_notifications
for invalid in 0 -1 abc 2147484; do
  if (NOTIFICATIONS_INTERVAL_SECONDS="$invalid"; validate_notifications) >/dev/null 2>&1; then
    echo 'Invalid notification interval accepted' >&2
    exit 1
  fi
done
export NOTIFICATIONS_EMAIL_ENABLED NOTIFICATIONS_EMAIL_FROM_EMAIL SENDGRID_TEMPLATE_NOTIFICATION
prepare_optional_secret_paths
compose_files
compose config --format json > "$TEST_ROOT/render.json"
jq -e '.services["influence-notifications"] |
  .environment.NOTIFICATIONS_EMAIL_ENABLED == "1" and
  .environment.SENDGRID_API_KEY_FILE == "/run/secrets/sendgrid_api_key" and
  .environment.NOTIFICATIONS_EMAIL_FROM_EMAIL == "sender@example.com" and
  .command == ["node", "/opt/influence-stack/run-periodic.js", "60", "src/workers/notifications.js"] and
  (.secrets | any(.source == "sendgrid_api_key")) and
  (.networks | has("edge") | not)' "$TEST_ROOT/render.json" >/dev/null
if grep -q fixture-key "$TEST_ROOT/render.json"; then exit 1; fi
compose() { printf '%s\n' "$*" > "$TEST_ROOT/action"; }
sync_notifications
[ "$(cat "$TEST_ROOT/action")" = '--profile notifications up -d --no-deps influence-notifications' ]
NOTIFICATIONS_EMAIL_ENABLED=0
sync_notifications
[ "$(cat "$TEST_ROOT/action")" = '--profile notifications stop influence-notifications' ]
notification_queue
[ "$(cat "$TEST_ROOT/action")" = '--profile tools run --rm --no-deps -T influence-tools bin/notification-queue.js' ]
printf 'Notification opt-in, credentials, interval, lifecycle, and server command checks passed\n'
