#!/usr/bin/env bash

configure_prerelease_webhook() {
  [ "$#" -eq 0 ] || die "Usage: ./stack configure-webhook"
  load_env
  [ "${STACK_ENVIRONMENT:-production}" = prerelease ] || die "Webhook deployment is prerelease-only"
  require_command jq
  validate_secret_file prerelease_webhook_token || die "Install prerelease_webhook_token first"
  [[ "${PRERELEASE_WEBHOOK_LISTEN_IP:-}" =~ ^[0-9a-fA-F:.]+$ ]] \
    || die "Set PRERELEASE_WEBHOOK_LISTEN_IP to the interface address reached by the proxy"
  mkdir -p "$STATE_DIR"
  local temporary
  temporary="$(mktemp "$STATE_DIR/prerelease-hooks.XXXXXX")"
  jq -n --rawfile token "$(secret_file prerelease_webhook_token)" \
    --arg command "$STACK_ROOT/stack" --arg directory "$STACK_ROOT" '
    [{
      id: "refresh-stack-prerelease",
      "execute-command": $command,
      "command-working-directory": $directory,
      "pass-arguments-to-command": [{source: "string", name: "prerelease-update"}],
      "http-methods": ["POST"],
      "trigger-rule-mismatch-http-response-code": 403,
      "response-message": "Deployment queued; inspect the webhook service journal for the result.",
      "trigger-rule": {match: {
        type: "value", value: ($token | gsub("[\\r\\n]"; "")),
        parameter: {source: "header", name: "X-Webhook-Token"}
      }}
    }]' > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$STATE_DIR/prerelease-hooks.json"
  printf 'WEBHOOK_LISTEN_IP=%s\n' "$PRERELEASE_WEBHOOK_LISTEN_IP" > "$STATE_DIR/prerelease-webhook.env"
  chmod 600 "$STATE_DIR/prerelease-webhook.env"
  info "Generated private webhook configuration; restart the receiver after token rotation"
}

resolve_release_channel() {
  local channel="$1"
  local digest
  [[ "$channel" =~ ^ghcr\.io/[a-z0-9._-]+/influence-(server|client):stack-prerelease$ ]] \
    || die "Expected a GHCR Influence stack-prerelease channel"
  digest="$(docker buildx imagetools inspect "$channel" --format '{{.Manifest.Digest}}')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Registry returned an invalid image digest"
  printf '%s@%s\n' "${channel%:*}" "$digest"
}

# Test candidate configuration before replacing the live pins.
# shellcheck disable=SC2030,SC2031
prerelease_update() (
  set -Eeuo pipefail
  [ "$#" -eq 0 ] || die "Usage: ./stack prerelease-update"
  load_env
  [ "${STACK_ENVIRONMENT:-production}" = prerelease ] || die "Automatic updates are prerelease-only"
  [ "${ENABLE_PRERELEASE_UPDATES:-0}" = 1 ] || { info "Prerelease updates are disabled"; exit 0; }
  [ -s "$STATE_DIR/bootstrap-complete" ] || die "Bootstrap must complete before enabling automatic updates"
  require_command flock
  require_command docker
  require_command jq
  exec 9> "$STATE_DIR/prerelease-update.lock"
  flock 9
  load_env
  [ ! -e "$STATE_DIR/prerelease-update-failed" ] \
    || die "Previous update failed; inspect the journal and resolve it before removing .state/prerelease-update-failed"
  compose_files
  validate_configuration
  ensure_juno_image_applied

  local server_image client_image
  server_image="$(resolve_release_channel "$PRERELEASE_SERVER_CHANNEL")"
  client_image="${INFLUENCE_CLIENT_IMAGE:-}"
  if [ "${ENABLE_CLIENT:-0}" = 1 ]; then
    client_image="$(resolve_release_channel "$PRERELEASE_CLIENT_CHANNEL")"
  fi
  if [ "$server_image" = "$INFLUENCE_SERVER_IMAGE" ] \
    && [ "$client_image" = "${INFLUENCE_CLIENT_IMAGE:-}" ]; then
    exit 0
  fi

  local candidate_dir
  candidate_dir="$(mktemp -d "$STATE_DIR/prerelease-candidate.XXXXXX")"
  trap 'rm -rf -- "$candidate_dir"' EXIT
  cp "$ENV_FILE" "$candidate_dir/env"
  chmod 600 "$candidate_dir/env"
  (
    ENV_FILE="$candidate_dir/env"
    replace_env_value INFLUENCE_SERVER_IMAGE "$server_image"
    if [ "${ENABLE_CLIENT:-0}" = 1 ]; then
      replace_env_value INFLUENCE_CLIENT_IMAGE "$client_image"
    fi
  )
  # A failure requires review, rather than retrying a broken release on every notification.
  printf 'server=%s\nclient=%s\n' "$server_image" "$client_image" > "$STATE_DIR/prerelease-update-failed"
  (
    ENV_FILE="$candidate_dir/env"
    INTEGRATION_RECEIPT="$candidate_dir/receipt"
    integration_test
  )

  cp "$ENV_FILE" "$STATE_DIR/prerelease-previous.env"
  chmod 600 "$STATE_DIR/prerelease-previous.env"
  mv "$candidate_dir/env" "$ENV_FILE"
  mv "$candidate_dir/receipt" "$INTEGRATION_RECEIPT"
  load_env
  compose_files
  require_integration_test
  local services=(
    influence-server influence-indexer influence-event-processor
    influence-ethereum-event-retriever influence-starknet-event-retriever
    influence-event-auditor influence-agreement-auditor
  )
  if [ "${ENABLE_CLIENT:-0}" = 1 ]; then services+=(influence-client); fi
  compose --profile indexer --profile auditor up -d --no-deps "${services[@]}"
  wait_for_required_application_health
  sync_notifications
  rm "$STATE_DIR/prerelease-update-failed"
  info "Prerelease application images deployed successfully"
)
