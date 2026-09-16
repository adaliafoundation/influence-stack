# Prerelease / Sepolia deployment

The same Compose services and `./stack` commands support production/mainnet and
prerelease/Sepolia. `STACK_ENVIRONMENT` selects the server configuration for every
API, worker, auditor, and tool, and the client's public runtime preset. The client
still uses `NODE_ENV=production` to serve its optimized bundle. The server uses
`NODE_ENV=prerelease` to load its existing prerelease contracts and integrations.
Setting `NODE_ENV` in the stack's `.env` does not select the environment.

## Configure a separate deployment

Use a separate checkout, `.env`, `client.env`, `secrets/`, `.state/`, and data root.
Run `./stack init`, then edit the following values together in `.env`:

```dotenv
STACK_ENVIRONMENT=prerelease
JUNO_NETWORK=sepolia
COMPOSE_PROJECT_NAME=influence-prerelease
DATA_ROOT=/influence-prerelease-data
HEALTH_NAMESPACE=prerelease
API_DOMAIN=api-prerelease.example.com
CLIENT_URL=https://prerelease.example.com
IMAGES_SERVER_URL=https://api-prerelease.example.com
ENABLE_CLIENT=1
CLIENT_DOMAIN=prerelease.example.com
JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/sepolia/latest
JUNO_SNAPSHOT_KIND=full
BACKUP_REPOSITORY=sftp:influence-backup:influence-prerelease
BACKUP_HOST=influence-prerelease
BACKUP_TAG=influence-prerelease
OTEL_ENVIRONMENT=prerelease
OTEL_HOST_NAME=influence-prerelease
```

Replace the example domains. Set `MONGO_DATABASE` to the actual application database
and `MONGO_RESTORE_SOURCE_DATABASE` to the database inside the dump. Verify the
source database name rather than assuming it matches the destination name.

Keep immutable server and client image digests. Use the server's production-target
image containing the prerelease configuration and the stack's direct Node entry
points; the legacy `:prerelease` image is not automatically the same artifact.
`./stack integration-test` verifies that the selected server image loads
`SN_SEPOLIA`, as well as testing authenticated storage connections.

Install **Ethereum Sepolia** URLs in `alchemy_juno_ethereum_ws_url` (WebSocket) and
`alchemy_influence_ethereum_http_url` (HTTPS). Copy
`config/client.env.example` to `client.env` and provide public **Starknet Sepolia**
and **Ethereum Sepolia** providers, IPFS, and the appropriate AVNU endpoint. Review
wallet/OAuth origin allowlists and all enabled integrations. Keep provisioning and
payments disabled until their test credentials, product IDs, and signer are ready.
The selected preset and stack API URL override values in `client.env`.

The `latest` snapshot is not guaranteed to match the pinned Juno release. Verify
its version before bootstrap; the installer refuses a mismatch. If necessary,
choose a compatible version-specific snapshot or deliberately update and test the
Juno image/version pins together. Size the extraction reserve and resource limits
for the host and snapshot. Snapshot staging supports flat databases and the
`juno_sepolia` / `juno_sepolia_pruned` wrapper directories.

The CLI rejects mismatched environment/network pairs and official snapshot URLs
for the other network. Custom mirrors and actual provider network identities still
need operator verification. Direct `docker compose` uses the same variables but
does not run CLI validation; use `./stack config` before starting services.

## Bootstrap and validate

For a fresh host, use the normal preparation, integration test, and bootstrap
sequence from the [deployment runbook](deployment-runbook.md), substituting a
consistent Sepolia Mongo dump and the configuration above. Fresh bootstrap still
requires a dump; prerelease support does not add reconstruction from chain origin.

Both Ethereum and Starknet retrievers are required by the stack's health and
convergence checks, alongside the processor and Elasticsearch indexer. Confirm the
dump's checkpoints are appropriate for Sepolia and available from the providers.
Verify the public client runtime configuration selects `prerelease`, then test
wallet login, API requests, and event/index updates using Sepolia.

## Local development clients

The prerelease API can serve both the hosted client and clients running on a
developer's machine. The server's existing origin policy allows `localhost`
origins when `NODE_ENV=prerelease`, including `http://localhost:3000` and
`http://localhost:5173`. The API routes and Socket.IO configuration use that shared
origin policy. Keep `CLIENT_URL` set to the hosted client's HTTPS URL; it is also
used for generated links and does not need to be replaced with localhost.

In the local client checkout, configure:

```dotenv
REACT_APP_CONFIG_ENV=prerelease
REACT_APP_API_INFLUENCE=https://api-prerelease.example.com
```

Replace the API domain and configure the local client's public Sepolia providers
as usual. Restart the client development server after editing its environment.
Open it using `localhost`, not `127.0.0.1`: the existing localhost exception does
not include the numeric loopback address. Requests reach the remote API through
Caddy on HTTPS/443, including WebSocket upgrades; the API container's port 3001
does not need to be exposed. Authentication still uses the usual signed challenge
and JWT flow, and any wallet/OAuth integration must allow the local client origin.

After deployment, test a local client as well as the hosted one: API
requests/preflights, wallet login, and live event updates. Production does not gain
the prerelease localhost exception from this stack change.

## Optional deployment features

Use [Automatic prerelease deployment](prerelease-deployments.md) to deploy verified
server/client releases through authenticated GitHub workflow notifications. The
feature is opt-in and requires a completed bootstrap and off-host backups. An
[external reverse proxy](external-proxy.md) can replace the default managed Caddy
on either a fresh host or an existing installation.

## Production compatibility

Existing production `.env` files can omit `STACK_ENVIRONMENT` and `JUNO_NETWORK`:
they default to `production` and `mainnet`. Image pins, paths, ports, pruning,
service topology, credentials, and backup settings are unchanged. Explicit
`HEALTH_NAMESPACE` values retain precedence. `./stack init` adds the new settings
without replacing existing values.

The changed Compose/scripts invalidate the saved image integration receipt. Before
the next production deploy, rerun `./stack integration-test`; it uses the configured
server digest and also tests the client when enabled. The server check verifies
`SN_MAIN`; an image that fails must be corrected before deployment. Pulling the repository alone
does not restart containers or change data.

Do not turn a production checkout into prerelease by changing its selector. Its
data, secrets, domains, and checkpoints belong to mainnet. Use the separate
deployment above. A different Compose project name alone does not isolate bind
mounts. Running both environments on one host also requires resolving Caddy's
80/443 bindings and Juno's host port; use the external-proxy mode and distinct Juno host ports when sharing a host.
Separate data roots and deployment checkouts are still required.
