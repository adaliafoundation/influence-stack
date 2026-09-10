#!/bin/sh
set -eu

app_password="$(tr -d '\r\n' < /run/secrets/mongo_app_password)"

case "${MONGO_APP_USERNAME}${MONGO_INITDB_DATABASE}${app_password}" in
  *[!A-Za-z0-9._~-]*)
    echo "Mongo application credentials contain unsupported characters." >&2
    exit 1
    ;;
esac

mongosh --quiet "$MONGO_INITDB_DATABASE" --eval "
  db.createUser({
    user: '${MONGO_APP_USERNAME}',
    pwd: '${app_password}',
    roles: [{ role: 'readWrite', db: '${MONGO_INITDB_DATABASE}' }]
  })
"

