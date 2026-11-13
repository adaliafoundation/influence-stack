# Automatic prerelease deployment

Prerelease can update automatically when the server or client release workflow
publishes a verified image. Production stays pinned and manually deployed. This
works on a fresh installation and does not depend on any earlier stack.

## Release contract

The server's `docker-stack-prerelease.yaml` workflow runs on pushes to `main` and
reuses the production image's test, build, scan, smoke-test, and signing pipeline.
It selects the `prerelease` GitHub environment and publishes the hardened image
under `stack-prerelease-<commit>` and `stack-prerelease`. It does not modify the
production or latest aliases. The manual production workflow retains its existing
environment, approval policy, and aliases. Configure the GitHub `prerelease`
environment without required reviewers if fully automatic releases are intended.

The client release workflow promotes its tested and signed digest to
`stack-prerelease`. Both repositories only advance this alias when the released
commit is still the head of `main`. A manually released older commit therefore
does not roll prerelease back.

Manual runs of `docker-stack-prerelease.yaml` can also release a commit from the
selected repository branch. Non-main runs require `workflow_dispatch` and validate
that the full source SHA belongs to that branch. They publish only the immutable
`stack-prerelease-<commit>` image reference, without advancing any shared alias or
notifying the deployment webhook. Production releases remain main-only.

After publication of a main-head release, each workflow sends an authenticated POST to the configured
deployment endpoint. The receiver accepts no commands, image names, or shell
arguments from the request. It runs `./stack prerelease-update`, which resolves
the configured release channels to immutable digests. Duplicate and late
notifications pick up the currently published images. Requests wait on one lock,
then reread `.env`, so overlapping server/client releases are serialized.

For a changed image pair, the updater:

1. Tests candidate pins using a temporary environment file and integration receipt.
2. Saves the previous `.env` in `.state/prerelease-previous.env` and installs the
   tested pins and receipt.
3. Recreates only application services and waits for their health checks.

Automatic updates do not dump MongoDB, upload a backup, or pause writers for a
backup. Daily scheduled backups and manual `./stack backup` remain available.
Take a manual backup before a server change that needs a fresh recovery point.

Juno, MongoDB, Redis, Elasticsearch, and Caddy are not upgraded by this command.
The stack checkout is not automatically pulled. Application releases must remain
compatible with the deployed stack configuration; configuration changes are an
operator action.

## Deploy prospecting branches without merging main

This sequence assumes an already bootstrapped **Sepolia** stack. For a fresh
installation, complete [prerelease setup](prerelease.md) first. Do not relabel a
mainnet stack/database as prerelease.

### 1. Commit and push the deployment support

The client and server feature code is on `prospecting`. The additional branch-CI
changes must be committed and pushed there as well. Before committing the client,
run its required `npm run audit:security` check. The stack changes are isolated on
`prospecting`; commit and push that branch separately.
No merge to main is required. GitHub already registers the existing prerelease
workflow on the default branch; `--ref` selects the feature branch's workflow code.

In both application repositories, check **Settings → Environments → prerelease**.
If deployment branches are restricted, allow `prospecting` alongside `main`.
Production environment rules do not need to change.

### 2. Build and publish the two branch images

From a terminal authenticated with GitHub CLI:

```sh
gh workflow run docker-stack-prerelease.yaml --repo adaliafoundation/influence-server --ref prospecting
gh workflow run docker-stack-prerelease.yaml --repo adaliafoundation/influence-client --ref prospecting
```

Alternatively use each repository's **Actions → Release prerelease image → Run
workflow**, selecting `prospecting`. These are the prerelease wrappers, not the
manual production workflows. All existing image tests, scans and signing remain.

Wait for both workflows to complete successfully. Copy the immutable
`ghcr.io/...@sha256:...` references from their run summaries, or download
`production-image/production-image.txt` (server) and `client-image/client-image.txt`
(client). Each reference identifies one exact commit; keep the SHA and digest in
your release notes. A published candidate or a successful build step alone is not
a completed release.

### 3. Switch the host to the isolated stack branch

On the existing Sepolia host, as the stack's operator account, enter its checkout.
If the automatic webhook receiver is enabled, wait for any update to finish and
stop the receiver under its deployment lock before changing files:

```sh
flock .state/prerelease-update.lock -c 'sudo systemctl stop influence-prerelease-webhook.service'
```

Then obtain the stack changes (first checkout of this new branch):

```sh
git fetch origin
git switch --track origin/prospecting
```

For subsequent updates on that branch, use `git pull --ff-only`.
Set the following in the host's untracked `.env`, replacing the digest placeholders:

```dotenv
ENABLE_PRERELEASE_UPDATES=0
INFLUENCE_SERVER_IMAGE=ghcr.io/adaliafoundation/influence-server@sha256:SERVER_DIGEST
INFLUENCE_CLIENT_IMAGE=ghcr.io/adaliafoundation/influence-client@sha256:CLIENT_DIGEST
ENABLE_CLIENT=1
```

Keep its existing `STACK_ENVIRONMENT=prerelease`, `JUNO_NETWORK=sepolia`, domains,
secrets, database and data-root settings. Disabling automatic updates prevents a
later main release from replacing the branch images.

### 4. Configure encrypted retention

Choose a separate public hostname for the retention peer, point its DNS to the
stack's proxy, and set in `.env` (replace the example hostname):

```dotenv
ENABLE_PRIVATE_DATA=1
PRIVATE_DATA_DOMAIN=private-data.YOUR_DOMAIN
```

The managed Caddy proxy provisions TLS and forwards WebSockets to the worker.
For an external proxy, configure HTTPS/WebSocket forwarding on that hostname to
`COMPOSE_PROJECT_NAME-private-data:15179` on the shared edge network. No host port
15179 needs publishing. Persistent data, including the peer's identity seed, lives
under `DATA_ROOT/private-data`; the worker has no database or API secret mounts.

In `client.env`, keep prospecting local until the contracts are activated:

```dotenv
REACT_APP_APP_PROSPECTINGMODE=local
```

Leave `REACT_APP_APP_PRIVATEDATAPEERS` empty until the peer's first startup gives
you its full `/p2p/...` address. Existing public provider and authentication settings
remain in this file. Then run:

```sh
./stack prepare-host
./stack config
./stack integration-test
```

Integration tests use temporary stores, including a disposable retention directory;
they never initialize or change the live peer identity. They verify worker startup
but do not replace a public DNS/TLS/browser acceptance test.

### 5. Prepare the new database indexes before processing prospecting events

From the same checkout and `.env`, use the selected server image's tools service:

```sh
docker compose --env-file .env --profile tools run --rm --no-deps influence-tools bin/create_prospecting_indexes.js
docker compose --env-file .env --profile tools run --rm --no-deps influence-tools bin/elasticsearch.js updateMapping --type deposit --version 1
docker compose --env-file .env --profile tools run --rm --no-deps influence-tools bin/elasticsearch.js updateMapping --type building --version 1
docker compose --env-file .env --profile tools run --rm --no-deps influence-tools bin/elasticsearch.js updateMapping --type lot --version 1
```

These use the live stack stores and preserve existing data. If the deployment uses
a different Elasticsearch index version, select its corresponding schema version.
A bulk legacy-deposit conversion or mass reindex is not required.

### 6. Deploy the applications and obtain the peer address

```sh
./stack deploy
./stack status
./stack logs influence-private-data
```

The ready log contains a public address of the form
`/dns4/YOUR_PRIVATE_DATA_DOMAIN/tcp/443/wss/p2p/PEER_ID`.
Exit log following with Ctrl-C; that does not stop the worker.
Put the **actual full printed address** in `client.env`:

```dotenv
REACT_APP_APP_PRIVATEDATAPEERS=/dns4/YOUR_PRIVATE_DATA_DOMAIN/tcp/443/wss/p2p/PEER_ID
```

Add the literal absolute path to the private-data directory to `backup-paths.txt`
if using the stack's off-host backups. Preserve `peer.seed` with the records across
restarts/restores; a different identity needs a different browser retention grant.

### 7. Deploy/activate contracts, then enable chain mode

Only after the new server is healthy, deploy/register the prospecting systems,
`GrantOffchainStarterPack`, verifier/adapter and mission implementation updates on
Sepolia. Keep the legacy finish/collection systems registered. Follow the contract
repository's `docs/prospecting-contracts.md` activation order, ending with the admin
`ConfigureProspecting` call. No SDK update is needed for the branch-release changes.

After activation, set in `client.env`:

```dotenv
REACT_APP_APP_PROSPECTINGMODE=chain
```

Then validate the final runtime configuration and redeploy:

```sh
./stack integration-test
./stack deploy
./stack status
```

### 8. Verify in a browser

Check wallet login and key unlock, then commit a sample and confirm the sidebar
reports remote backup acknowledgment. Reload and recover the campaign; browser
proof generation, finalization, extraction and collection must all work on Sepolia.
Also finish an old running sample/improvement from the prospecting sidebar, and
verify a legacy claim plus any pre-existing running extraction remain usable.
Confirm new starter grants supply 10 / 15 / 20 sampling uses.

For another branch release, repeat the two manual workflows, update the image
pins, rerun integration and deploy. No moving branch tag or merge is necessary.

## Set up a new installation

Complete the [prerelease setup](prerelease.md), client configuration, image
integration test, and bootstrap first. Configure [daily off-host backups](off-host-backups.md)
separately; automatic updates do not require backup credentials.
Use the `influence` operator account and `/home/influence/influence-stack` checkout
for the supplied systemd unit. Docker Buildx is needed to resolve registry digests.

```sh
sudo apt-get update
sudo apt-get install -y webhook util-linux docker-buildx-plugin
docker buildx version
```

If GHCR packages are private, log in to GHCR as `influence` with a read-only package
credential. The unattended receiver uses that account's Docker credentials.

Set these values in `.env`, using your organization's image repositories:

```dotenv
ENABLE_PRERELEASE_UPDATES=1
PRERELEASE_SERVER_CHANNEL=ghcr.io/adaliafoundation/influence-server:stack-prerelease
PRERELEASE_CLIENT_CHANNEL=ghcr.io/adaliafoundation/influence-client:stack-prerelease
```

Choose the host interface reached by your proxy for `PRERELEASE_WEBHOOK_LISTEN_IP`.
For this stack's Docker Caddy with the standard Docker host-gateway mapping, inspect
the bridge gateway:

```sh
docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'
```

Put that address in `.env`; do not assume it is always `172.17.0.1`. If the Docker
daemon overrides `host-gateway`, use that configured address instead. A host-native
proxy can use `127.0.0.1`. Bind to the private interface, not a public wildcard.
Do not expose port 9000 to the internet.

Generate a unique random webhook token in your password manager and install it
through the hidden prompt:

```sh
./stack install-secret prerelease_webhook_token
./stack configure-webhook
./stack integration-test
./stack deploy
sudo install -m 0644 config/systemd/influence-prerelease-webhook.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now influence-prerelease-webhook.service
```

The generated hook configuration contains the token, is mode 0600, and stays in
ignored `.state/`. Managed Caddy automatically routes
`https://API_DOMAIN/hooks/refresh-stack-prerelease` to the receiver. An external
proxy must install the equivalent route from [External proxy](external-proxy.md).
The receiver verifies `X-Webhook-Token` and accepts POST only.

In **each** application repository, configure:

- Actions variable `STACK_PRERELEASE_WEBHOOK_URL`:
  `https://your-api-domain/hooks/refresh-stack-prerelease`.
- Actions secret `STACK_PRERELEASE_WEBHOOK_TOKEN`: the same token installed above.

A blank URL disables notification; releases can still publish normally. Set the
URL only after the receiver and routing are ready. Test `./stack prerelease-update`
manually once; it must pass the same integration and health gates.

## Operations and failures

The webhook acknowledges that deployment was queued, not that it succeeded.
The supplied service enables logging; command output appears after the deployment
command finishes. Inspect the result on the host:

```sh
journalctl -u influence-prerelease-webhook.service --since today
./stack status
```

Integration failure leaves the live `.env` and containers unchanged.
Once deployment begins, failure leaves the candidate pins in place and may leave
a mix of application container versions. All update attempts stop while
`.state/prerelease-update-failed` exists. Inspect the journal and service state,
correct the failure, and use `./stack integration-test` and `./stack deploy` to
complete recovery. Remove the failure marker only after reviewing the state.

There is no automatic image rollback: a server release may already have changed
Mongo data. The saved previous `.env` preserves the prior image pins, but does not
restore database state. Database recovery uses your latest independently taken backup. Neither queued HTTP acceptance nor a successful workflow is a
substitute for monitoring application health and deployment failures.

Before manually editing or updating the checkout/configuration, disable workflow
notifications and wait for active deployment commands to finish, then stop the
receiver. Do not change `.env` concurrently with an automatic deployment. Token
rotation requires updating both repository secrets, running `configure-webhook`,
and restarting the receiver. Stopping the service during an active deployment can
interrupt it; the failure marker requires review before resuming.
