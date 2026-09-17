# Influence deployment stack

Docker Compose deployment for running the Influence API, indexers, data stores,
and a local Juno Starknet node on a dedicated server. Production/mainnet is the
default; prerelease/Sepolia is also supported.

## Acknowledgment: Chvx's foundational work

This stack was inspired by **[Chvx's influence-container-stack](https://github.com/Chvx/influence-container-stack)**.
Chvx made a substantial contribution by putting together and documenting a
practical, containerized Influence environment for the community: the client and
API, MongoDB, Redis, Elasticsearch, event retrieval and processing, and a local
Juno node running against Starknet Sepolia.

The original repository's service layout and hands-on instructions for preparing
persistent storage, synchronizing Juno, restoring a prerelease database, building
search indices, and rebuilding the packed lot cache directly informed this
project. That work provided an important foundation for the deployment approach
here. **Thank you, Chvx, for making Influence easier to run and develop locally.**

This repository extends those ideas into an operational deployment stack with
immutable images, managed secrets, health checks, TLS, and off-host backups. See
the [original repository and guide](https://github.com/Chvx/influence-container-stack)
for the community development setup and the inspiration behind this project.

## Operator documentation

Start with the [deployment runbook](docs/deployment-runbook.md) for the ordered
path from a fresh host through a source database dump, bootstrap, acceptance
checks, and cutover planning. It includes recovery choices for interrupted runs.

- [Automatic prerelease deployment](docs/prerelease-deployments.md): release webhooks, digest updates, and recovery.
- [External proxy](docs/external-proxy.md): use your own reverse proxy instead of managed Caddy.
- [Prerelease deployment](docs/prerelease.md): Sepolia setup, local development clients, and production compatibility.
- [Client deployment](docs/client-image-deployment.md): runtime configuration, DNS, and browser checks.
- [Off-host backups](docs/off-host-backups.md): Storage Box access, encryption, retention, scheduling, and restore testing.
- [OpenTelemetry logging](docs/opentelemetry.md): collector setup and Mezmo troubleshooting.
- [Optional integrations](docs/optional-integrations.md): credentials, feature flags, and acceptance checks.

The sections below describe the command and configuration contracts in detail.

This project also reuses the official container image, worker commands,
Elasticsearch tooling, and provisioner key-file contract from
[adaliafoundation/influence-server](https://github.com/adaliafoundation/influence-server).

Set `STACK_ENVIRONMENT=prerelease` and `JUNO_NETWORK=sepolia` for a separate
Sepolia deployment. Follow [Prerelease deployment](docs/prerelease.md) for the
matching providers, snapshot, domains, and data settings.

## Relationship to the Chvx stack

This is a fresh production implementation rather than a fork of the Chvx files.
The Chvx project remains the reference for the current community prerelease setup,
and its useful service split, local Juno pattern, restore flow, and packed-cache
rebuild procedure informed this stack.

Production has materially different boundaries: released server images instead of
live source mounts, generated service credentials, role-scoped application secrets,
automatic TLS, restore validation, ordered catch-up, health gates, backups, and
provider-ready logging. Keeping those concerns here avoids complicating the simple
community development stack. Prerelease uses the same deployment machinery with
its own network, image, database, and endpoint configuration.

## What it runs

- Influence API and image routes
- Ethereum and Starknet event retrievers
- Event processor and Elasticsearch indexer
- Event and agreement auditors
- MongoDB 7, Redis 7.2, and Elasticsearch 8.19
- Juno, seeded from a compatible snapshot for the selected network
- Caddy for automatic HTTPS and WebSocket proxying

The event and agreement auditors run once when their containers start, then wait
one hour after each run completes before running again. Configure the delays with
`EVENT_AUDIT_INTERVAL_SECONDS` and `AGREEMENT_AUDIT_INTERVAL_SECONDS` (both default
to `3600`). Runs do not overlap, and failed runs use the same delay. Stopping an
auditor container forwards the shutdown signal to its active job.

Only HTTP and HTTPS are publicly exposed. Juno RPC is bound to localhost for
operator health checks; MongoDB, Redis, and Elasticsearch are available only on
the Docker data network.

All containers log to stdout and stderr using rotated Docker JSON logs and stable
component labels. This works with host collectors such as Mezmo's Docker agent,
Fluent Bit, or an OpenTelemetry collector without coupling the stack to one vendor.

## Requirements

- A dedicated Linux server with Docker Engine and the Docker Compose plugin (`docker compose`)
- An x86-64 host (the current Influence production image is built for `linux/amd64`)
- `curl`, `jq`, OpenSSL, GNU tar, `sha256sum`, and `zstd` on the host
- Fast SSD or NVMe storage mounted at `/influencedata` by default
- Enough free space for the compressed and extracted pruned Juno mainnet
  snapshot (currently approximately 99 GB compressed)
- DNS for the API hostname pointed at the server
- Two Ethereum Mainnet Alchemy endpoints:
  - WebSocket for Juno L1 verification
  - HTTP for the Influence Ethereum event retriever
- A gzip-compressed `mongodump --archive` containing an Influence database

Fresh production bootstrap deliberately requires a Mongo dump. The current server
can bootstrap a missing chain checkpoint near the recent chain head, which is not
sufficient to reconstruct a complete production database from nothing.

## Bootstrap model

This is a fresh-server workflow, not a cutover tool. It does not modify or coordinate
with an existing Heroku, Atlas, or hosted Elasticsearch deployment.

MongoDB is the supplied restore point and source of saved Ethereum and Starknet
checkpoints. The stack then:

1. Seeds Juno from a current snapshot and catches it up using an Ethereum WebSocket
   endpoint.
2. Restores MongoDB and verifies that entities and both chain checkpoints exist.
3. Starts Redis empty; runtime data is repopulated by the application. The durable
   packed-lot cache is restored from MongoDB or rebuilt when absent.
4. Recreates Elasticsearch as derived state and indexes every stored entity.
5. Starts both event retrievers at their restored checkpoints, then waits for event
   processing and the Elasticsearch queue to drain near the current chain heads.
6. Starts the public API and HTTPS edge only after those gates pass.

## Quick start

Initialize protected local service credentials and a runtime configuration:

```sh
./stack init
```

`init` is the only secret-file creation step. It creates the protected `secrets/`
directory, generates the MongoDB, Redis, Elasticsearch, and JWT credentials, and
creates empty files for external credentials. It also derives complete MongoDB,
Redis, and Elasticsearch connection-URI files for the application. Do not manually
construct those URIs or create one file per service.

Supply the two required external credentials using hidden prompts:

```sh
./stack install-secret alchemy_juno_ethereum_ws_url
./stack install-secret alchemy_influence_ethereum_http_url
```

Alternatively, import either value from an existing owner-readable file by passing
its path as the second argument. Optional provider credentials only need to be
installed when their corresponding feature is enabled. See
[Configuration and secrets](#configuration-and-secrets) for the full contract.

Edit `.env`, replacing the example domains, URLs, and server image pin. Then prepare
the persistent directories and validate the resulting Compose configuration:

```sh
./stack prepare-host
./stack config
```

The Alchemy endpoints are secret files, not `.env` entries; only replace the
domains, image pin, and other non-secret settings in `.env`.

With Docker running and configuration complete, test the images configured in
`.env` without downloading Juno or requiring a Mongo dump:

```sh
./stack integration-test
```

The test uses `INFLUENCE_SERVER_IMAGE` and the pinned datastore images. It creates
unique credentials, a temporary Compose project, and temporary volumes, then checks
the selected chain preset and authenticated MongoDB, Redis, and Elasticsearch
access from the released server image.

When `ENABLE_CLIENT=1`, `INFLUENCE_CLIENT_IMAGE` must also be pinned by digest. The
same test pulls and starts that image with the configured public `client.env` and
Compose overrides. It checks health, served runtime configuration (including the
network preset, API URL, and provider URLs), HTML, and JavaScript assets. It does
not start Caddy, publish client ports, or contact the real API or providers. This
is an image smoke test, not a browser or end-to-end test: wallet login, browser
execution, API compatibility, and public TLS routing still need acceptance checks.
With client hosting disabled, no client image is required or tested.

All test credentials, containers, and volumes are removed afterward. On ARM-based
Macs, Docker Desktop emulates the production `linux/amd64` server container while
the datastore containers run natively.

An optional argument tests a candidate server image without editing `.env`:

```sh
./stack integration-test ghcr.io/adaliafoundation/influence-server@sha256:CANDIDATE_DIGEST
```

The override applies only to the server; an enabled client still uses its digest
from `.env`. Set the tested server digest in `.env` before deploying it.

A passing test records the selected server digest and a fingerprint of the
effective Compose configuration and deployment scripts under `.state/`. That
fingerprint includes the enabled client image digest and rendered public runtime
configuration. Changing either image, client configuration, or other fingerprinted
inputs requires a fresh test before `bootstrap`, `deploy`, or `update`. The receipt
is written only after all enabled checks pass.

Bootstrap the entire stack from a MongoDB archive:

```sh
./stack bootstrap --mongo-dump /secure/path/influence.archive
```

Bootstrap downloads and installs the official weekly Juno snapshot, restores
MongoDB, rebuilds Elasticsearch, starts the workers in dependency order, waits
for Juno and the Influence checkpoints to catch up, and finally exposes the API.

Bootstrap detects a completely absent packed lot cache and rebuilds it. Use
`--rebuild-packed-cache` to force the same rebuild when the supplied dump contains
stale or incomplete packed lot data:

```sh
./stack bootstrap \
  --mongo-dump /secure/path/influence.archive \
  --rebuild-packed-cache
```

### Resume after a completed Mongo restore

If an initial bootstrap restored MongoDB successfully but failed afterward, stop
that bootstrap before retrying. After updating the stack, rerun the image
integration test to refresh its configuration fingerprint, then use:

```sh
./stack bootstrap --resume-after-restore
```

This explicitly skips the archive restore and rechecks the existing entities,
chain checkpoints, packed cache, and Juno checkpoint availability. It then rebuilds
Elasticsearch and continues normal catch-up and API startup. Use it only after a
confirmed complete restore, before the new deployment serves production traffic.
It cannot be combined with `--mongo-dump`, and completed deployments are rejected.
It does not skip validation or resume Elasticsearch halfway through indexing.

### Resume after indexing has started

If bootstrap timed out during catch-up, use this mode to preserve MongoDB,
Elasticsearch indices, the existing index queue, and the packed lot cache:

```sh
./stack bootstrap --resume-after-indexing
```

It validates existing data, Juno, and search aliases, starts workers, waits for
convergence and worker health, then starts the API and TLS proxy. It marks bootstrap
complete only after API health passes. Indexing can still be in progress when this
command starts. It does not restore a dump, seed Juno, reset search, enqueue a full
reindex, or rebuild the packed cache. Missing prerequisites cause it to stop.
Other bootstrap modes and `--rebuild-packed-cache` cannot be combined with it.
Normal configuration and image integration checks still apply.

## Operations

```sh
./stack status
./stack logs
./stack backup
./stack integration-test
./stack deploy
./stack update
./stack restart-juno
./stack upgrade-juno
```

`update` creates a MongoDB backup before pulling and recreating containers.
The backup command briefly pauses application writers so its collection data and
saved chain checkpoints form a consistent restore point. It uploads the Mongo dump
and deployment configuration/secrets to an encrypted off-host Restic repository,
then removes the temporary local archive. Remote access is required; it never falls
back to a local-only backup. Configure the Storage Box, encryption password, daily
timer, and retention using [Off-host backups](docs/off-host-backups.md) before
running `backup`, `update`, or `upgrade-juno`.

`restart-juno` performs a controlled restart without changing the pinned image.
It stops the Starknet event retriever, gives Juno time to shut down cleanly,
waits for Juno to become synchronized and ready again, verifies the saved MongoDB
checkpoint is still queryable, and only then resumes the retriever.

To upgrade Juno, first update `JUNO_IMAGE` and
`JUNO_SNAPSHOT_EXPECTED_VERSION` together after reviewing the upstream migration
notes, then run `./stack upgrade-juno`. The command pulls the new image before
downtime, creates a MongoDB backup, and follows the same gated restart sequence.
If migration, synchronization, or checkpoint validation fails, the retriever
stays stopped for investigation. Because a Juno database migration may not be
reversible, the command does not attempt an automatic image rollback.

The general `deploy` and `update` commands refuse to apply a changed Juno image;
Juno upgrades must pass through `upgrade-juno`.

The API, Elasticsearch indexer, Ethereum retriever, Starknet retriever, and event
processor each have role-specific health checks. The API is ready only when its
stores and all four workers report fresh successful progress. Deploy and update
wait for these checks, and every Influence API, worker, auditor, and tool service
is validated to use the same `INFLUENCE_SERVER_IMAGE` digest.

## Configuration and secrets

Configuration is split by sensitivity and by when it is consumed:

| Input | Where it is set | When it is consumed |
| --- | --- | --- |
| Stack and server non-secrets | `.env` on the server | Container startup |
| Server/provider secrets | `secrets/`, via `./stack install-secret` | Container startup |
| Starter-pack signer key | `/etc/influence/secrets`, via `./stack install-signer-key` | API startup when provisioning is enabled |
| Client `REACT_APP_*` values | `client.env` when client hosting is enabled | Client container startup; always public |

The normal server setup therefore has one `.env` file and two prompted Alchemy
values. Internal passwords are generated automatically. Stripe, SendGrid, Banxa,
AVNU, IPFS, marketplace, and Argent values remain empty unless those integrations
are actually used. `./stack config` fails closed when a required value is missing,
an enabled feature lacks credentials, a secret file is too broadly readable, or an
image is not pinned by digest.

Mongo startup copies its two host-owned secret files into a private tmpfs directory
owned by the image's `mongodb` user before invoking the official entrypoint. Host
files retain their owner-only permissions; runtime copies are mode 0400 and never
written into the image or persistent database volume. Production and integration
tests use the same startup path.

Compose mounts secrets as files and supplies only their paths through variables such
as `MONGO_URL_FILE=/run/secrets/mongo_url`. Influence Server reads each file directly
into its application configuration; secret values are not copied into `.env`, the
rendered Compose configuration, or the process environment. Optional integrations
receive a `_FILE` setting only when their installed secret file is non-empty.

MongoDB, Redis, and Elasticsearch still require their individual password files to
start. The application additionally requires complete connection URIs, so `init`
derives `mongo_url`, `redis_url`, and `elasticsearch_url` from those passwords.
`config`, `bootstrap`, `deploy`, and `update` regenerate the derived files atomically,
which keeps them synchronized after a credential, username, or database-name change.
All mounted secrets remain readable by the application user, and Docker access
remains equivalent to root access on the host.

Client configuration is public configuration, not secrets. The client image now
serves an allowlisted runtime configuration generated from its container
environment, so the same immutable image can run in prerelease and production.
It must still be built and published by the client repository rather than compiled
on the production server. The contract is documented in
[Client image deployment](docs/client-image-deployment.md).

## Prepare Juno before obtaining the Mongo dump

On the new host, you can download the snapshot and synchronize Juno before taking
an up-to-date production MongoDB dump:

```sh
./stack init
./stack install-secret alchemy_juno_ethereum_ws_url
# Review DATA_ROOT and the JUNO_* settings in .env.
./stack prepare-host
./stack prepare-juno
```

`prepare-juno` starts only Juno. It does not require application domains, an
Influence image integration receipt, the Ethereum HTTP credential, or a Mongo dump.
It validates the Juno image/version, retention settings, and protected WebSocket
credential. The standalone Compose file also defines the service reused by the
production stack, with the same project, networks, and persistent data path.

The snapshot downloads directly to the host. The command waits for synchronization
and readiness, then leaves Juno running. If the wait times out, Juno continues
running; rerun the command to resume waiting. Existing node data is reused and
partial downloads resume when the upstream archive still matches. Keep the project
name, data path, and Juno image settings unchanged between preparation and bootstrap.
After bootstrap completes, use `restart-juno` or `upgrade-juno` instead.

Once Juno is ready, obtain a consistent Mongo dump and transfer it to the host.
Complete the application configuration and image integration test described above,
then run the normal bootstrap:

```sh
./stack bootstrap --mongo-dump /secure/path/influence.archive
```

Bootstrap reuses the prepared node and still checks that the restored chain
checkpoint is queryable before starting retrievers. The combined bootstrap remains
available when you already have a suitable dump.

## Optional IPFS storage

The server image must include the provider-neutral IPFS configuration contract.
Set `IPFS_RPC_URL` in `.env` to a Kubo-compatible API root including `/api/v0`.
Set `IPFS_GATEWAY_URL` to the gateway base before `/ipfs/<CID>` when needed by
setup tooling; configure the frontend gateway independently. Both default to empty.
Without an RPC endpoint, uploads return HTTP 503 while local hashing and database
reads remain available.

For an authenticated endpoint, install the complete Authorization header (for
example `Bearer <token>`) using the hidden prompt:

```sh
./stack install-secret ipfs_rpc_authorization
```

Compose mounts `secrets/ipfs_rpc_authorization` into the API container and supplies
`IPFS_RPC_AUTHORIZATION_FILE=/run/secrets/ipfs_rpc_authorization` only when the file
is nonempty. Leave it empty for an unauthenticated private endpoint. The header is
never placed in `.env` or the container environment. Recreate the API container
after rotating it so the file is remounted and the application reloads it.

On an existing checkout, rerun `./stack init` to add the URL settings and new secret
file. Old Infura key files are no longer mounted or used; they are not automatically
converted or deleted. Install the credential required by the chosen provider.
Changing providers does not migrate existing pins. Publish and pin a server image
containing the new IPFS implementation, then rerun the image integration test before
deploying the changed configuration.

## Juno bootstrap

The normal bootstrap path uses Nethermind's latest weekly pruned mainnet
snapshot:

```text
https://juno-snapshots.nethermind.io/files/mainnet-pruned/latest
```

Snapshot transfers use HTTP/1.1 and retry transport interruptions up to five times,
resuming saved bytes and rechecking upstream metadata between attempts. Connections
time out after 30 seconds; transfers stalled below 1 KiB/s for two minutes are
retried. Partial files remain available if retries are exhausted.

Downloads are resumable and extraction happens in a staging directory before
the database is installed. Bootstrap checks the upstream filename against the
pinned Juno version, verifies the downloaded content length, and reserves the
configured extraction space before downloading. Set `JUNO_SNAPSHOT_SHA256` when
a trusted source publishes a checksum. Without one, bootstrap warns and relies
on HTTPS, archive integrity, Juno database validation, L1 verification, and RPC
checks.

The `latest` snapshot URL intentionally fails closed when Nethermind advances it
to a different Juno database version. Update and test the pinned image, digest,
and `JUNO_SNAPSHOT_EXPECTED_VERSION` together before retrying.

Juno is pinned by release and image digest to v0.16.6 and exposes RPC v0.10 to
Influence. It runs with a 128-block floor plus a 720-hour minimum age, so at least
30 days of block data are retained after the node has accumulated that history.
The stack explicitly selects `/v0_10` for both application RPC providers and its
host-side Juno checks. Use server/client images with RPC v0.10 support and configure
browser RPC providers, including backup providers, for v0.10 as well.

When upgrading an existing deployment, set `JUNO_RPC_VERSION=v0_10` in `.env`;
`./stack init` preserves an existing explicit value. If the setting is absent,
the new default takes effect on the next deployment. This applies to production
as well as prerelease. Deploy compatible application images together with the
endpoint change, rerun `./stack integration-test`, and verify wallet login and
event retrieval against the running node. The isolated integration test does not
contact Juno or external browser RPC providers.

The Starknet event retriever does not start until Juno reports synchronization
complete, its readiness endpoint passes, and the restored MongoDB checkpoint can
actually be queried from Juno.

The upstream pruned snapshot keeps only its recent pruning window; increasing
`JUNO_PRUNE_MIN_AGE` cannot restore history already removed from the archive.
That is acceptable for the initial deployment when the Mongo dump is current:
Juno catches forward from the weekly snapshot, and bootstrap does not start the
retriever until the Mongo checkpoint is queryable. The node then accumulates up
to 30 days of retained history.

If a restored Mongo checkpoint predates the pruned snapshot's retained range,
bootstrap stops before starting any worker. The emergency recovery procedure is
to use the full snapshot instead:

```dotenv
JUNO_SNAPSHOT_URL=https://juno-snapshots.nethermind.io/files/mainnet/latest
JUNO_SNAPSHOT_KIND=full
JUNO_SNAPSHOT_EXTRACTION_RESERVE_GB=700
```

The full archive is currently approximately 530 GB, so emergency recovery needs
substantially more temporary disk space and download time. It provides the
historical range needed to recover from an older weekly MongoDB backup.

## Starter pack and crewmate provisioning

Provisioning is disabled by default. Production private keys must never be placed
in `.env`.

`prepare-host` creates an operator-only system secret directory. Securely install
the dedicated Starknet account private key with:

```sh
./stack install-signer-key /secure/path/private-key
```

It is copied to:

```text
/etc/influence/secrets/starter_pack_admin_private_key
```

The file must contain only the private key and must be mode `0400` or `0600`.
The stack refuses to enable provisioning when the file is more broadly readable.
Then set:

```text
ENABLE_PROVISIONER=1
STARTER_PACK_PROVISIONER_ENABLED=1
CREWMATE_PROVISIONER_ENABLED=1
STARKNET_STARTER_PACK_ADMIN=0x...
```

Complete the required Stripe product and webhook configuration before enabling
the feature. `compose.provisioner.yaml` mounts the key read-only at the path already
supported by Influence Server:

```text
/run/secrets/starter_pack_admin_private_key
```

Use a dedicated account authorized only for the required Dispatcher role and keep
only enough ETH on it for transaction fees.

## Banxa checkout

Banxa uses authenticated order polling to refresh status directly from its API.
Install `banxa_api_key`, set `BANXA_PARTNER_REF`, and enable
`BANXA_CHECKOUT_ENABLED=1`. Webhook credentials are not required. See the
[polling setup](docs/optional-integrations.md#banxa-polling-setup) for details.

## Logging

Application, database, Juno, and Caddy logs are emitted to stdout and stderr.
Caddy and Juno emit JSON. Docker retains five 25 MB files per container locally.

An optional OpenTelemetry Collector forwards Docker logs to Mezmo over OTLP/HTTP.
It runs independently of the application stack; see [OpenTelemetry logging](docs/opentelemetry.md)
for credentials, startup, environment labels, and collection limits.

## Security notes

- Service credentials are generated under `secrets/` and are ignored by Git.
- `.env` is ignored by Git and created with mode `0600`.
- The transaction-signing key is kept outside the repository checkout.
- Database ports are not published.
- The provisioner key is a read-only Compose secret used only by the API service.
- Caddy's administration endpoint is disabled.
- Application and Juno containers run as the operator UID with a read-only root
  filesystem, dropped Linux capabilities, and `no-new-privileges`.
- Configure host firewalling, security updates, disk monitoring, and encrypted
  off-host backups as part of server provisioning.

## Deferred work

These additions fit the design but are intentionally deferred from the first
production bootstrap:

- Full database reconstruction from chain origin without a Mongo dump
- Multi-host MongoDB or Elasticsearch high availability

### Elasticsearch secret ownership

Elasticsearch stages its password in a private tmpfs directory before starting
as UID 1000. The short initialization step runs as root to read an owner-only
Compose secret regardless of the operator's UID; the source stays unchanged.
Health checks and indexing setup use the staged copy. This applies to production,
prerelease, and isolated integration tests. Updating this configuration requires
an integration test and recreating Elasticsearch on the next deployment; the
image, data ownership, and database password are unchanged. It does not reset
an existing database's credentials.
