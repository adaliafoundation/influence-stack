#!/bin/sh
set -eu

# Compose bind-mounted secrets retain their host UID and mode. Stage private
# copies before the official entrypoint drops privileges to mongodb.
install -d -m 0700 -o mongodb -g mongodb /run/mongo-secrets
for name in mongo_root_password mongo_app_password; do
  [ -s "/run/secrets/$name" ] || {
    echo "Missing or empty Mongo secret: $name" >&2
    exit 1
  }
  install -m 0400 -o mongodb -g mongodb "/run/secrets/$name" "/run/mongo-secrets/$name"
done

exec /usr/local/bin/docker-entrypoint.sh "$@"
