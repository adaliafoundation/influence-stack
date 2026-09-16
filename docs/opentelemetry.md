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

## Verify delivery and troubleshoot

Pipeline edits must be deployed in Mezmo. Inspect a fresh source sample, then find
the same message in Log Analysis. Use ordinary worker logs or make a request to the
client/API to generate activity. Do not infer delivery from collector startup alone.

For an OTEL source sample, resource fields are under
`message.resource.attributes` and the body is `message.record.body`. Mezmo's
template paths start inside `message`; dots inside attribute names need quoting:

| Destination field | Template / field path |
| --- | --- |
| Hostname | `{{ .resource.attributes."host.name" }}` |
| Line | `{{ .record.body }}` |
| App | `{{ .resource.attributes."service.name" }}` |
| Env | `{{ .resource.attributes."deployment.environment.name" }}` |
| File | `{{ .record.attributes."log.file.path" }}` |
| Meta Field | `.resource.attributes` (field path, not a template) |

During deployment testing, Log Analysis used resource `service.name` for its app
label even when the destination's App override was set. This is an observation,
not a confirmed provider bug or a guarantee about other pipeline configurations.
The collector now sets that attribute directly. No intermediate processor is
required by this stack. Remove any temporary diagnostic message prefixes after
testing. In Log Analysis inspect `_app`, `_host`, and `_line`; resource keys in
`_meta` may be normalized with underscores.

| Symptom | Check |
| --- | --- |
| No fresh destination logs | Pipeline is deployed; logs output connects to the intended destination; collector has no persistent export errors. |
| `UNKNOWN_APP` | Check `service.name` in a fresh source record and that the updated collector configuration is loaded. `service.namespace` is a different field. |
| Every app is `influence` | Older containers lack Compose service labels in their log envelopes. Labels appear on normal recreation, not just restart. |
| Secret `permission denied` | Pull current collector configuration, including its user/capability settings; keep the key mode 0600. Reissuing the key does not fix filesystem permissions. |
| Core services reported as orphans | Use the explicit `-p influence-observability` commands above. Do not use `--remove-orphans` against the core project. |

Changes to the bind-mounted collector YAML require a collector restart; `up -d`
alone does not detect edits inside mounted files:

```sh
docker compose -p influence-observability -f compose.observability.yaml restart otel-collector
```

For Compose/environment changes, use `up -d` to recreate with the new settings.

Mongo's authenticated healthcheck runs every ten seconds and can generate multiple
informational connection/authentication records. Worker polling/delay messages and
Juno `Stored Block` logs are also routine. Diagnose warnings/errors and lack of
progress separately from log volume. Any noise filtering should preserve failures.
