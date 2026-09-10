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
```

Set `REACT_APP_STARKNET_PROVIDERBACKUP` and `REACT_APP_ETHEREUM_PROVIDER` when the
client features in use require them. Add public client IDs such as Privy, Google,
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

## Stack work still required

The client repository now contains the multi-stage image, runtime configuration,
tests, and release workflow. This stack still needs a client service and Caddy
route pinned to a released client digest. Until that is added, the API stack can
be deployed independently while the client remains on its current hosting platform.
