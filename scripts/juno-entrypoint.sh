#!/bin/sh
set -eu

secret_path=/run/secrets/alchemy_juno_ethereum_ws_url
if [ ! -r "$secret_path" ]; then
  echo "Missing required secret: $secret_path" >&2
  exit 1
fi

ethereum_node="$(tr -d '\r\n' < "$secret_path")"
case "$ethereum_node" in
  wss://*) ;;
  *)
    echo "Juno Ethereum provider must be a wss:// URL" >&2
    exit 1
    ;;
esac

exec /usr/local/bin/juno --eth-node "$ethereum_node" "$@"
