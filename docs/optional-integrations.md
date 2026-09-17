# Optional integration checklist

Enable one integration at a time after core browser checks pass. These are the
stack inputs and acceptance checks. Provider dashboard settings and exact webhook
routes/events must match the released server/client implementation; do not guess
them from a generic provider example. Payment handover needs a rehearsal.

## Configuration workflow

- Set server non-secrets and feature flags in `.env`.
- Install server credentials with `./stack install-secret NAME`, using the hidden
  prompt or a protected file as its second argument.
- Put public browser configuration in `client.env`. RPC keys in these URLs are
  visible to visitors. Use separate browser keys with provider-supported origin
  restrictions and quotas; never include server signing keys or privileged keys.
- Allow the temporary client origin at applicable providers. This environment
  still uses mainnet; its temporary hostname does not make transactions test-only.

After configuration, test the configured images:

```sh
./stack config
./stack integration-test
./stack deploy
```

The integration test covers server configuration and datastore access, plus client
startup and served configuration/assets when enabled. It does not verify provider
authentication, payment, delivery, or fulfillment. Verify the feature and logs separately. Recreate affected
containers after secret rotation so credentials are reloaded.

## Inputs and acceptance checks

| Integration | Stack inputs | Acceptance check |
| --- | --- | --- |
| Wallets / Google / Privy / WalletConnect | Public IDs/URLs in `client.env`; see [client configuration](client-image-deployment.md). Secret `argent_api_key` if required by the enabled server integration. | Supported login flows, reconnects, and callbacks work from the temporary origin. |
| IPFS | `IPFS_RPC_URL`, `IPFS_GATEWAY_URL`; secret `ipfs_rpc_authorization` when required. Client gateway configured separately. | Application upload and retrieval of its CID succeed; existing pins remain available. See [IPFS setup](../README.md#optional-ipfs-storage). |
| SendGrid | Secret `sendgrid_api_key`; sender/template settings and `NOTIFICATIONS_EMAIL_ENABLED`. | Verified sender and intended template deliver to an operator-controlled recipient; old and new deployments do not send duplicate notifications. |
| Stripe + provisioning | Secrets `stripe_secret_key`, `stripe_webhook_secret`; product IDs, provisioner flags, admin account, and signer key. See [signer setup](../README.md#starter-pack-and-crewmate-provisioning). | Payment, callback signature validation, fulfillment, and repeated callbacks produce the expected result without duplicate fulfillment. |
| AVNU paymaster | Secret `avnu_paymaster_api_key`; `AVNU_PAYMASTER_ENABLED`, budget, rate, and timeout settings. | Controlled sponsored action succeeds; rejected/over-budget requests are handled correctly. |
| Banxa | Secret `banxa_api_key`; `BANXA_PARTNER_REF`, `BANXA_CHECKOUT_ENABLED`. No webhook credentials required. | Checkout succeeds and authenticated order polling updates the status from Banxa. |
| Marketplace | Secret `open_sea_api_key` when required; review `ELEMENT_CHAIN`. | Applicable marketplace views return expected mainnet data. |
| Mezmo | Secret `mezmo_ingestion_key`, collector settings, deployed pipeline. | Fresh logs have host/service labels and alerts reach an operator. See [logging](opentelemetry.md). |

For payments and signing, record the provider account/mode, products, exact callback
URL/events, and which deployment owns fulfillment. Use provider test facilities
where supported, then an explicitly controlled mainnet acceptance test. Two copies
of the database do not share callback deduplication state.

## Banxa polling setup

```sh
./stack install-secret banxa_api_key
```

Set in `.env`:

```dotenv
BANXA_CHECKOUT_ENABLED=1
BANXA_PARTNER_REF=YOUR_PARTNER_REFERENCE
```

The client polls the authenticated `GET /v2/banxa/orders/:orderId` endpoint;
the server refreshes the order from Banxa before returning its status. No Banxa
webhook destination or webhook credentials are needed for this flow. The server
image still contains a webhook route, and the stack retains optional secret mounts
for compatibility; leave those secret files empty for a new polling-only setup.
Existing webhook credentials are not deleted by this change.

Validate and deploy as above, then test checkout with a deployed Starknet wallet
and verify that order polling reaches the expected status. Stripe's webhook setup
is independent and remains required for Stripe provisioning.

## Alerts

Assign an operator and a tested delivery destination for API outages, stalled
workers, backup failures/stale snapshots, disk pressure, and persistent log export
failures. The backup timer records failures in the journal but does not send alerts.
A running collector alone does not prove delivery to the log destination.

## Email notification worker

Email delivery is disabled by default. After verifying the sender, API key, and
active SendGrid dynamic template with a test email, inspect the pending queue:

```bash
./stack notification-queue
```

The stack invokes `node bin/notification-queue.js` from the configured server image.
Publish and select a server image containing that command before using it; older
images do not include it. Queue selection and inspection are owned by the server.

This command reads counts and the oldest eligible timestamp without sending,
removing, or displaying notification contents or recipient addresses. Eligible
counts are documents due within the last 30 days, not a count of emails: the
server groups notifications and filters them using recipient preferences and
notification-specific conditions. Older documents are ignored by the worker.

Before enabling delivery, stop notification jobs on the previous deployment to
avoid duplicate sends. Review the backlog: enabling the service immediately
processes eligible notifications, including older ones within that 30-day window.

Set the following in `.env`:

```dotenv
NOTIFICATIONS_EMAIL_ENABLED=1
NOTIFICATIONS_INTERVAL_SECONDS=60
NOTIFICATIONS_EMAIL_FROM_EMAIL=your-verified-sender@example.com
NOTIFICATIONS_EMAIL_FROM_NAME=Influence Notifications
SENDGRID_TEMPLATE_NOTIFICATION=d-your-active-template-id
```

Install `sendgrid_api_key` with `./stack install-secret sendgrid_api_key`. Then run
`./stack integration-test` and `./stack deploy`. This starts one
`influence-notifications` service using the pinned server image and existing
periodic runner. Runs do not overlap within that container; each finishes before
the configured delay starts. Do not scale this service to multiple replicas.
Follow its output with `./stack logs influence-notifications`.

Manual deployments and prerelease updates apply the notification setting. Setting
it back to `0` and deploying stops an existing notification service. For an
immediate stop before deploying, run from the checkout:

```bash
(
  source ./stack
  load_env
  compose_files
  compose --profile notifications stop influence-notifications
)
```

Backups pause the notification worker with the other database writers. Its
process status is not proof of email delivery: the existing server worker can
log an error and exit successfully. Check its logs and SendGrid delivery activity.
