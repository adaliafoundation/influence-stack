#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
# shellcheck source=stack
source "$REPO_ROOT/stack"
STACK_ROOT="$TEST_ROOT"
ENV_FILE="$TEST_ROOT/.env"
cp "$REPO_ROOT/.env.example" "$ENV_FILE"
mkdir "$TEST_ROOT/secrets"
load_env
API_DOMAIN=api.test.invalid
CADDY_EMAIL=ops@test.invalid
CLIENT_URL=https://game.test.invalid
IMAGES_SERVER_URL=https://api.test.invalid
INFLUENCE_SERVER_IMAGE="ghcr.io/adaliafoundation/influence-server@sha256:$(printf '%064d' 1)"
for secret in mongo_root_password mongo_app_password mongo_url redis_password redis_url \
  elasticsearch_password elasticsearch_url jwt_secret banxa_api_key; do
  printf 'test-only-value\n' > "$TEST_ROOT/secrets/$secret"
done
printf 'https://ethereum.test.invalid\n' > "$TEST_ROOT/secrets/alchemy_influence_ethereum_http_url"
printf 'wss://ethereum.test.invalid\n' > "$TEST_ROOT/secrets/alchemy_juno_ethereum_ws_url"
touch "$TEST_ROOT/secrets/banxa_webhook_api_key" "$TEST_ROOT/secrets/banxa_webhook_secret"
chmod 600 "$TEST_ROOT"/secrets/*
BANXA_CHECKOUT_ENABLED=1
BANXA_PARTNER_REF=test-partner
validate_configuration
if (BANXA_PARTNER_REF=; validate_configuration) > "$TEST_ROOT/error" 2>&1; then
  echo 'Missing Banxa partner reference should fail validation' >&2
  exit 1
fi
: > "$TEST_ROOT/secrets/banxa_api_key"
if (validate_configuration) > "$TEST_ROOT/error" 2>&1; then
  echo 'Missing Banxa API key should fail validation' >&2
  exit 1
fi
echo 'Banxa polling configuration checks passed'
