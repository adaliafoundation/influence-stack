#!/bin/sh
set -eu

# Compose secrets retain host ownership. Stage a private copy before dropping
# privileges, without changing the source file or persisting another password.
install -d -m 0700 -o 1000 -g 0 /run/elasticsearch-secrets
[ -s /run/secrets/elasticsearch_password ] || {
  echo "Missing or empty Elasticsearch password" >&2
  exit 1
}
install -m 0400 -o 1000 -g 0 /run/secrets/elasticsearch_password /run/elasticsearch-secrets/elasticsearch_password
exec setpriv --reuid=1000 --regid=0 --clear-groups /bin/tini -- /usr/local/bin/docker-entrypoint.sh "$@"
