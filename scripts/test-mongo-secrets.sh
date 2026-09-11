#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="$(docker compose --env-file "$REPO_ROOT/.env.example" -f "$REPO_ROOT/compose.yaml" config --format json | jq -r '.services.mongo.image')"
name="influence-mongo-permissions-$$"
volume="$name-secrets"
# Invoked by the EXIT trap.
# shellcheck disable=SC2329
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Set ownership inside Linux, even when tests run on Docker Desktop.
docker volume create "$volume" >/dev/null
docker run --rm --entrypoint sh -v "$volume:/secrets" "$image" -ec '
  printf "test-root-password" > /secrets/mongo_root_password
  printf "test-app-password" > /secrets/mongo_app_password
  chown 1000:1000 /secrets/*
  chmod 0600 /secrets/*
'
docker run -d --name "$name" --network none --security-opt no-new-privileges:true \
  --tmpfs /data/db:size=512m --tmpfs /run/mongo-secrets:size=1m,mode=0700 \
  -v "$volume:/run/secrets:ro" \
  -v "$REPO_ROOT/scripts/mongo-entrypoint.sh:/opt/influence-stack/mongo-entrypoint.sh:ro" \
  -v "$REPO_ROOT/scripts/mongo-init-app-user.sh:/docker-entrypoint-initdb.d/10-app-user.sh:ro" \
  -e MONGO_INITDB_ROOT_USERNAME=influence_admin \
  -e MONGO_INITDB_ROOT_PASSWORD_FILE=/run/mongo-secrets/mongo_root_password \
  -e MONGO_APP_PASSWORD_FILE=/run/mongo-secrets/mongo_app_password \
  -e MONGO_INITDB_DATABASE=influence -e MONGO_APP_USERNAME=influence \
  --entrypoint /bin/sh "$image" /opt/influence-stack/mongo-entrypoint.sh mongod >/dev/null
for attempt in {1..60}; do
  logs="$(docker logs "$name" 2>&1)"
  if [[ "$logs" == *'MongoDB init process complete'* ]]; then break; fi
  if [ "$attempt" -eq 60 ]; then
    docker logs --tail 50 "$name"
    exit 1
  fi
  sleep 2
done
# Check source permissions are unchanged and staged secrets are private to Mongo.
docker exec "$name" sh -ec '
  test "$(stat -c %u:%a /run/secrets/mongo_root_password)" = 1000:600
  test "$(stat -c %u:%a /run/mongo-secrets/mongo_root_password)" = 999:400
  test "$(stat -c %u:%a /run/mongo-secrets/mongo_app_password)" = 999:400
'
for attempt in {1..15}; do
  if docker exec --user 999:999 "$name" mongosh --quiet --host localhost --eval '
    const fs = require("fs");
    const root = db.getSiblingDB("admin");
    root.auth("influence_admin", fs.readFileSync(process.env.MONGO_INITDB_ROOT_PASSWORD_FILE, "utf8"));
    if (!root.runCommand({ping: 1}).ok) quit(1);
    const app = new Mongo("mongodb://127.0.0.1:27017").getDB("influence");
    app.auth("influence", fs.readFileSync(process.env.MONGO_APP_PASSWORD_FILE, "utf8"));
    app.permission_test.insertOne({ok: true});
    if (!app.permission_test.findOne({ok: true})) quit(1);
  ' >/dev/null 2>&1; then
    echo 'Mongo root and application authentication passed with protected UID-1000 secrets'
    exit 0
  fi
  sleep 2
done
docker logs --tail 50 "$name"
exit 1
