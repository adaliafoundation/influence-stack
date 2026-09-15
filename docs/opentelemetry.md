# OpenTelemetry logging

The optional `compose.observability.yaml` runs the pinned upstream contrib
collector independently of bootstrap and deploy. No application image rebuild
or restart is required to begin collecting logs.

## Mezmo setup

Create a SaaS pipeline and add an OpenTelemetry Source. Connect it to a destination
and deploy the pipeline. A source alone does not provide retained, searchable logs.
To use the existing Mezmo log viewer, configure a Log Analysis destination and its
required field mapping; verify the mapping against a received sample before relying
on search. Keep the ingestion key on the box, not in Git or pasted command lines.

References: [collector](https://docs.mezmo.com/telemetry-pipelines/otel-collector),
[source](https://docs.mezmo.com/telemetry-pipelines/open-telemetry-source),
[destination](https://docs.mezmo.com/telemetry-pipelines/mezmo-destination).

## Start on the Docker host

From the stack checkout (always use `-p influence-observability`, since the core
stack's `COMPOSE_PROJECT_NAME` in `.env` overrides the Compose file's name):

```sh
./stack install-secret mezmo_ingestion_key
docker info --format '{{.DockerRootDir}}'
```

The default Docker root is `/var/lib/docker`. If yours differs, set
`DOCKER_CONTAINERS_PATH` in `.env` to its `containers` subdirectory. This collector
requires Docker's `json-file` log driver, used by the stack.

Optional `.env` configuration (these are the defaults):

```dotenv
OTEL_ENVIRONMENT=prerelease
OTEL_HOST_NAME=influence-next
OTEL_EXPORTER_OTLP_ENDPOINT=https://logs.mezmo.com/otel
DOCKER_CONTAINERS_PATH=/var/lib/docker/containers
```

```sh
docker compose -p influence-observability -f compose.observability.yaml run --rm --no-deps otel-collector \
  validate --config=/etc/otelcol/config.yaml
docker compose -p influence-observability -f compose.observability.yaml up -d
docker compose -p influence-observability -f compose.observability.yaml logs --tail=50 -f otel-collector
```

Confirm fresh records arrive at the Mezmo source and then the destination. Filter
on `deployment.environment.name=prerelease` and `host.name=influence-next`.
Successful collector startup alone does not prove delivery; check for export errors.

At cutover set `OTEL_ENVIRONMENT=production`, choose the production host label,
and repeat the collector `up -d` command. Only subsequent records get new labels.

## Collection behavior

- Reads all `*-json.log` files under the configured Docker containers directory,
  including other projects on the host. Use this on the dedicated Influence box.
- First discovery starts at the end of each file. Historical logs, and early lines
  written before discovery of a new container, are not backfilled.
- Docker envelopes are decoded into a message body, timestamp, stream, and container
  ID. Application JSON remains a string body for downstream parsing.
- New/recreated stack containers include the Compose service label in their log
  envelopes. It becomes `service.name`, overriding the default `influence` used
  for existing containers without this label. All records also have `container.id`;
  do not recreate busy workers just for the service label.
  Map an ID with `docker ps --no-trunc --format '{{.ID}} {{.Names}}'`.
- Read positions and the bounded persistent export queue survive collector
  recreation in the `collector-state` Docker volume. Do not use `down -v` unless
  intentionally discarding that state. Rotation during extended downtime and
  permanent ingestion errors can still lose logs; this is not an archive backup.
- The collector uses Docker's `local` driver for its own logs to prevent feedback.
- Root is needed to read Docker's root-owned files. The directory is mounted
  read-only. Only `DAC_READ_SEARCH` is retained to read operator-owned mode-0600
  secrets; no Docker socket is mounted. No host
  ports are published. Metrics and traces are not collected in this initial setup.

To stop only collection:

```sh
docker compose -p influence-observability -f compose.observability.yaml stop
```
