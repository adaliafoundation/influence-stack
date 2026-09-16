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

After publication, each workflow sends an authenticated POST to the configured
deployment endpoint. The receiver accepts no commands, image names, or shell
arguments from the request. It runs `./stack prerelease-update`, which resolves
the configured release channels to immutable digests. Duplicate and late
notifications pick up the currently published images. Requests wait on one lock,
then reread `.env`, so overlapping server/client releases are serialized.

For a changed image pair, the updater:

1. Tests candidate pins using a temporary environment file and integration receipt.
2. Takes an encrypted off-host backup with the current deployment configuration.
3. Saves the previous `.env` in `.state/prerelease-previous.env` and installs the
   tested pins and receipt.
4. Recreates only application services and waits for their health checks.

Juno, MongoDB, Redis, Elasticsearch, and Caddy are not upgraded by this command.
The stack checkout is not automatically pulled. Application releases must remain
compatible with the deployed stack configuration; configuration changes are an
operator action.

## Set up a new installation

Complete the [prerelease setup](prerelease.md), client configuration, image
integration test, bootstrap, and [off-host backups](off-host-backups.md) first.
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
manually once; it must pass the same integration, backup, and health gates.

## Operations and failures

The webhook acknowledges that deployment was queued, not that it succeeded.
The supplied service enables logging; command output appears after the deployment
command finishes. Inspect the result on the host:

```sh
journalctl -u influence-prerelease-webhook.service --since today
./stack status
```

Integration or backup failure leaves the live `.env` and containers unchanged.
Once deployment begins, failure leaves the candidate pins in place and may leave
a mix of application container versions. All update attempts stop while
`.state/prerelease-update-failed` exists. Inspect the journal and service state,
correct the failure, and use `./stack integration-test` and `./stack deploy` to
complete recovery. Remove the failure marker only after reviewing the state.

There is no automatic image rollback: a server release may already have changed
Mongo data. The saved previous `.env` and off-host backup support a deliberate
rollback plan. Neither queued HTTP acceptance nor a successful workflow is a
substitute for monitoring application health and deployment failures.

Before manually editing or updating the checkout/configuration, disable workflow
notifications and wait for active deployment commands to finish, then stop the
receiver. Do not change `.env` concurrently with an automatic deployment. Token
rotation requires updating both repository secrets, running `configure-webhook`,
and restarting the receiver. Stopping the service during an active deployment can
interrupt it; the failure marker requires review before resuming.
