# Client image deployment contract

The Influence client is a separate immutable build artifact with an allowlisted
runtime-configuration endpoint. The same image digest can run against prerelease
or production:

1. The client repository's CI job checks out an exact commit.
2. CI tests and builds the environment-neutral production image.
3. CI scans and signs the image and publishes its immutable digest.
4. The stack supplies `REACT_APP_CONFIG_ENV=prerelease` or `production` and any
   operator-specific public overrides when the container starts.
5. The client serves those values from `/runtime-config.js` before its application
   bundle starts.

Do not pass credentials to the client build. Every `REACT_APP_*` value is visible
to anyone who downloads the site. Public provider identifiers must be domain- and
quota-restricted at the provider.

## Minimum production inputs

The client already contains production defaults for contract addresses and public
URLs. A normal production container should explicitly set at least:

```dotenv
REACT_APP_CONFIG_ENV=production
REACT_APP_API_INFLUENCE=https://api.example.com
REACT_APP_STARKNET_PROVIDER=https://your-public-starknet-rpc.example
REACT_APP_API_IPFS=https://your-ipfs-gateway.example/ipfs
REACT_APP_API_AVNU=https://your-public-avnu-api.example
REACT_APP_ETHEREUM_PROVIDER=https://your-public-ethereum-rpc.example
```

Set `REACT_APP_STARKNET_PROVIDERBACKUP` when needed. Add public client IDs such as Privy, Google,
WalletConnect, Stripe, or GTM to the stack's untracked runtime configuration only
when enabled.

The application config flattens JSON paths without inserting word-boundary
underscores. Important examples are:

| Application setting | Build variable |
| --- | --- |
| `Api.influence` | `REACT_APP_API_INFLUENCE` |
| `Api.argentWebWallet` | `REACT_APP_API_ARGENTWEBWALLET` |
| `Api.ClientId.google` | `REACT_APP_API_CLIENTID_GOOGLE` |
| `App.deployment` | `REACT_APP_APP_DEPLOYMENT` |
| `App.enableDevTools` | `REACT_APP_APP_ENABLEDEVTOOLS` |
| `Starknet.chainId` | `REACT_APP_STARKNET_CHAINID` |
| `Starknet.Address.dispatcher` | `REACT_APP_STARKNET_ADDRESS_DISPATCHER` |
| `Url.bridge` | `REACT_APP_URL_BRIDGE` |
| `Url.starknetExplorer` | `REACT_APP_URL_STARKNETEXPLORER` |

Legacy-looking aliases such as `REACT_APP_API_URL`, `REACT_APP_DEPLOYMENT`,
`REACT_APP_GOOGLE_API_KEY`, and `REACT_APP_STARKNET_EXPLORER_URL` are not read by
the current `src/appConfig/index.js`. They should be renamed in the client build
configuration instead of carried into the new deployment.

## Enable client hosting

The optional `compose.client.yaml` adds the client and its Caddy route. Set these
values in `.env`, using your real temporary hostnames:

```dotenv
ENABLE_CLIENT=1
CLIENT_DOMAIN=game-next.example.com
CLIENT_URL=https://game-next.example.com
INFLUENCE_CLIENT_IMAGE=ghcr.io/adaliafoundation/influence-client@sha256:c23cbd73637726afc6b20b3704a32c78546feded325d2fde542a39f58110d4d4
```

`CLIENT_URL` controls the API's allowed client origin and must match the client
hostname. `API_DOMAIN` remains the temporary API hostname. Point client DNS to the
box before starting Caddy. The client port is accessible only inside Docker.

```sh
cp config/client.env.example client.env
chmod 600 client.env
```

Edit `client.env` with your public mainnet RPC, IPFS gateway, and AVNU endpoints.
These four values are required; replace all example URLs. Copy public OAuth/wallet
client IDs and other enabled integrations from your current production client
configuration, and allow the temporary origin at those providers. Never copy
server secrets into this file. The API URL and network preset are supplied by
Compose and override this file.

Include provider-required API keys in browser RPC URLs, using the exact supported
endpoint from the provider. These URLs are public in `runtime-config.js`; use
separate browser credentials with provider-supported origin restrictions and
quotas, not private server credentials.

This temporary deployment mirrors mainnet: the service explicitly uses the
`production` preset. The client's `prerelease` preset selects testnet contracts
and must not be used for this mainnet migration.

After bootstrap, validate and refresh the integration receipt, then deploy:

```sh
./stack config
./stack integration-test ghcr.io/adaliafoundation/influence-server@sha256:8c3924021492a11204138d719850fb79557cc1849559182668ea3aa963cfadfd
./stack deploy
```

Use the server digest currently configured in `.env` if it has changed. Deploy
reconciles the full stack and may recreate services whose configuration changed.
The client image is pulled automatically if absent. Caddy waits for the client
health check, and deploy checks client health. The server integration test does
not test browser behavior.

Verify public routing with your real client hostname:

```sh
curl -I https://game-next.example.com/healthz
curl -fsS https://game-next.example.com/runtime-config.js
```

Expect HTTP 204 for health. Confirm runtime configuration selects `production`
and the temporary API URL, then test loading the game, wallet login, and API calls
in a browser. This does not perform a production DNS cutover. `client.env` is
ignored by Git and included in off-host backups.
