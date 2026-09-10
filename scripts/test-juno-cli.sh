#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rendered="$(docker compose --env-file "$REPO_ROOT/.env.example" -f "$REPO_ROOT/compose.juno.yaml" config --format json)"
image="$(jq -r '.services.juno.image' <<< "$rendered")"
args=()
while IFS= read -r arg; do
  args+=("$arg")
done < <(jq -r '.services.juno.command[]' <<< "$rendered")
# Parse the actual configured flags without starting a node or mounting live data.
docker run --rm --entrypoint /usr/local/bin/juno "$image" "${args[@]}" --help >/dev/null
printf 'Pinned Juno image accepts the configured CLI arguments\n'
