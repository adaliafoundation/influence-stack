#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="$(docker compose --env-file "$REPO_ROOT/.env.example" -f "$REPO_ROOT/compose.yaml" config --format json | jq -r '.services.elasticsearch.image')"
name="influence-elasticsearch-permissions-$$"
volume="$name-secrets"
# Invoked by the EXIT trap.
# shellcheck disable=SC2317,SC2329
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$volume" >/dev/null
# Create Linux ownership explicitly so Docker Desktop cannot mask a UID mismatch.
docker run --rm --user 0:0 --entrypoint sh -v "$volume:/secrets" "$image" -ec '
  printf "test-elastic-password" > /secrets/elasticsearch_password
  chown 1001:1001 /secrets/elasticsearch_password
  chmod 0600 /secrets/elasticsearch_password
'
docker run -d --name "$name" --network none --hostname localhost --user 0:0 \
  --security-opt no-new-privileges:true \
  --tmpfs /usr/share/elasticsearch/data:size=512m,uid=1000,gid=0 \
  --tmpfs /run/elasticsearch-secrets:size=1m,mode=0700 \
  -v "$volume:/run/secrets:ro" \
  -v "$REPO_ROOT/scripts/elasticsearch-entrypoint.sh:/entrypoint.sh:ro" \
  -e discovery.type=single-node -e xpack.security.enabled=true \
  -e xpack.security.http.ssl.enabled=false \
  -e ELASTIC_PASSWORD_FILE=/run/elasticsearch-secrets/elasticsearch_password \
  -e 'ES_JAVA_OPTS=-Xms512m -Xmx512m' \
  --entrypoint /bin/sh "$image" /entrypoint.sh eswrapper >/dev/null
for _ in {1..90}; do
  [ "$(docker inspect --format '{{.State.Running}}' "$name")" = true ] || break
  if docker exec --user 1000:0 "$name" sh -ec '
    test "$(stat -c %u:%a /run/secrets/elasticsearch_password)" = 1001:600
    test ! -r /run/secrets/elasticsearch_password
    test "$(stat -c %u:%a /run/elasticsearch-secrets/elasticsearch_password)" = 1000:400
    test "$(awk "/^Uid:/ {print \$2}" /proc/1/status)" = 1000
    curl -fsS -u "elastic:$(cat /run/elasticsearch-secrets/elasticsearch_password)" \
      "http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null
  ' >/dev/null 2>&1; then
    echo 'Elasticsearch authentication passed as UID 1000 with protected UID-1001 source credentials'
    exit 0
  fi
  sleep 2
done
docker logs --tail 50 "$name"
exit 1
