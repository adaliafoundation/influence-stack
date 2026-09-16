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

After configuration, use the current server digest from `.env`:

```sh
./stack config
./stack integration-test ghcr.io/adaliafoundation/influence-server@sha256:RELEASED_DIGEST
./stack deploy
```

The integration test covers datastore access, not provider authentication, payment,
delivery, or fulfillment. Verify the feature and logs separately. Recreate affected
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
