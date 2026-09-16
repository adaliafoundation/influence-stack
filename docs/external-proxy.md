# Use an existing reverse proxy

The default `EDGE_MODE=managed` runs the supplied Caddy service. A deployment can
instead use an existing Docker-connected reverse proxy:

```dotenv
EDGE_MODE=external
EDGE_NETWORK=web
COMPOSE_PROJECT_NAME=influence-prerelease
```

The network must already exist and the proxy must be connected to it. The stack
does not create or delete this external network. In this mode the stack's Caddy
service is excluded from normal bootstrap, deploy, update, and integration commands.
The proxy owns its own certificates, routes, and lifecycle. Do not explicitly
enable the `managed-edge` profile in external mode.

Stable aliases on that network are derived from `COMPOSE_PROJECT_NAME`:

| Service | Example upstream |
| --- | --- |
| API and images | `influence-prerelease-api:3001` |
| Optional client | `influence-prerelease-client:3000` |
| Juno RPC | `influence-prerelease-juno:6060` |

MongoDB, Redis, and Elasticsearch remain on the internal data network. The API
and client do not publish host ports. Juno retains its existing loopback port for
the stack's synchronization checks. Connecting Juno to the proxy network does not
automatically publish an RPC route; apply the proxy's own access and CORS policy
if one is needed.

For example, an external Caddy API site with automatic prerelease deployment uses:

```caddyfile
api.example.com {
    handle /hooks/refresh-stack-prerelease {
        reverse_proxy host.docker.internal:9000
    }
    handle {
        reverse_proxy influence-prerelease-api:3001
    }
}

game.example.com {
    reverse_proxy influence-prerelease-client:3000
}
```

Configure `host.docker.internal:host-gateway` in that Caddy container's `extra_hosts`
and bind the host webhook receiver to the corresponding gateway address. The
receiver authenticates the token. See [Automatic prerelease deployment](prerelease-deployments.md)
for the fresh-install setup. Without automatic deployment, omit the hook route.

Integration tests override the external edge network with a temporary private
network. They do not join the live proxy network or advertise test containers to
the real proxy. Public routing, TLS, and browser acceptance checks remain separate.
