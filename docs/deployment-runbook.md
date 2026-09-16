# Production deployment runbook

Run host commands as the `influence` operator unless a command uses `sudo`.
Replace example hostnames, usernames, and image digests before running commands.
This runbook stages a mainnet deployment alongside an existing deployment; it
does not automate stopping the old deployment or switching production traffic.

## 1. Prepare the host and checkout

Ubuntu 24.04 LTS is the baseline used for this deployment. Before cloning, finish
host provisioning: updates, a non-root operator with sudo and SSH key access,
Docker Engine and its Compose plugin, synchronized time, and firewall rules for
SSH and TCP 80/443 (UDP 443 permits HTTP/3). Verify the operator can log in through
a second SSH session before disabling direct root SSH login. Do not delete the
root account. Docker group membership grants root-equivalent host access.

Check the host:

```sh
cat /etc/os-release
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
cat /proc/mdstat
df -hT
systemctl --failed
timedatectl status
sudo ufw status
docker run --rm hello-world
docker compose version
```

On a two-member Linux software RAID1, `[UU]` means both members are present.
Wait for initial resynchronization to finish before planned reboots or the large
snapshot workload. RAID protects against a disk failure; it is not a backup.
On hosts without software RAID, `/proc/mdstat` does not provide this check.

Install operator tools and clone:

```sh
sudo apt update
sudo apt install -y git curl jq openssl tar coreutils zstd tmux restic openssh-client util-linux
git clone https://github.com/adaliafoundation/influence-stack.git
cd influence-stack
./stack init
```

Review `DATA_ROOT` in `.env` before `./stack prepare-host`. That command creates
`/influencedata` and its subdirectories by default; it does not partition or mount
a disk. If using a separate data filesystem, mount it there first.

For long-running commands:

```sh
tmux new -s influence-setup
```

Detach with **Ctrl+B, release, then lowercase d**. Return with
`tmux attach -t influence-setup`. Avoid pulling or editing the checkout while a
stack command is running from it. Detached Docker services continue running if
the operator terminal closes, but the foreground orchestration may stop.

## 2. Prepare Juno first

```sh
./stack install-secret alchemy_juno_ethereum_ws_url
./stack prepare-host
./stack prepare-juno
```

No server or client image is needed at this stage. The default snapshot is pruned
and downloads directly to this host. Interrupted downloads are resumable; see
the [Juno snapshot contract](../README.md#juno-bootstrap) for version and disk checks.

In another terminal, inspect progress:

```sh
docker compose -f compose.juno.yaml logs --tail=50 -f juno
```

`Stored Block` with advancing numbers indicates progress. Throughput varies;
estimate remaining time using several minutes of progress and a current chain
head, not a short burst of log lines. With the default RPC settings:

```sh
curl -fsS http://127.0.0.1:6060/v0_8 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"starknet_syncing","params":[]}'
```

`result: false` means synchronization is complete. `prepare-juno` also checks
readiness and then exits. If its wait times out, rerun it; existing node data is
reused. Do not delete Juno data to restart a wait.

## 3. Configure and test the server image

Choose temporary API and game DNS names pointing to this host. Set `API_DOMAIN`,
`CLIENT_URL`, `IMAGES_SERVER_URL`, `CADDY_EMAIL`, and `INFLUENCE_SERVER_IMAGE` in
`.env`. Keep the database name `influence` when that is the source database;
`MONGO_RESTORE_SOURCE_DATABASE` names the archive's database and `MONGO_DATABASE`
names the destination. These are independent of the Atlas cluster name/tier.

```sh
./stack install-secret alchemy_influence_ethereum_http_url
./stack config
./stack integration-test ghcr.io/adaliafoundation/influence-server@sha256:RELEASED_DIGEST
```

Use the exact server digest configured in `.env`, never the client digest.
Repeat the test after configuration changes invalidate its receipt. The test uses
temporary stores and does not alter the restored production database.

## 4. Take a consistent source dump

Do this after Juno is ready to minimize the age of the restore point. Inventory
and stop all writers on the source deployment: API writes, both retrievers,
event processor, indexer, auditors, scheduled jobs, webhook handlers, and any
external scripts. Pausing only the indexers is insufficient. Record the existing
process counts/settings so you can resume them after the dump. Commands to stop
them depend on how the source deployment is hosted.

An ordinary database dump is not a point-in-time snapshot if writes continue.
This workflow does not use oplog capture/replay. Run from the new host, permitting
its outbound IP in Atlas network access first:

```sh
umask 077
mkdir -p "$HOME/mongo-transfer"
# Use the Mongo tools image pinned in this checkout, not the Atlas patch version.
mongo_image="$(docker compose -f compose.yaml config --format json | jq -r '.services.mongo.image')"
docker pull "$mongo_image"
docker run --rm -it \
  --user "$(id -u):$(id -g)" \
  --mount type=bind,src="$HOME/mongo-transfer",dst=/backup \
  "$mongo_image" mongodump \
  --uri='mongodb+srv://YOUR_CLUSTER.mongodb.net/?authSource=admin' \
  --username='YOUR_DUMP_USER' \
  --db=influence --readPreference=primary \
  --archive=/backup/influence.archive --gzip
```

Enter the password at the prompt; use straight shell quotes. `authSource=admin`
selects the authentication database, while `--db=influence` selects the data.
Do not add `/admin` to the URI path. Wait for successful command completion and
collection progress, then confirm the archive is nonempty. For a staging copy,
resume the original production processes now. A final cutover requires a separate
write freeze and handover (below).

## 5. Bootstrap and monitor

```sh
./stack bootstrap --mongo-dump "$HOME/mongo-transfer/influence.archive"
```

Expect a nonzero restored document count and zero failed documents. Zero restored
documents is not a successful Influence restore; check the archive database name.
After restoration, search rebuild and catch-up can take hours:

```sh
./stack status
./stack logs influence-indexer
./stack logs influence-starknet-event-retriever
```

Small changing chain lags are normal. Look for advancing checkpoints, zero
unprocessed events, and a draining index queue. Queue entries can include multiple
requests for one entity, so queue length is not a distinct entity count. A queue
that stays flat or grows needs indexer/auditor logs inspected; do not repeatedly
rebuild search to clear it.

If orchestration stops, stop any still-running original command before retrying:

| Last successful stage | Resume command | Effect |
| --- | --- | --- |
| Juno preparation | `./stack prepare-juno` | Reuses data and waits again |
| Mongo restored, search rebuild still needed | `./stack bootstrap --resume-after-restore` | Skips restore, rebuilds search |
| Search indexing already started | `./stack bootstrap --resume-after-indexing` | Preserves search and queue, waits and starts API |
| Bootstrap completed | `./stack deploy` | Reconciles services and checks health |

After a checkout/configuration update, refresh the integration receipt first.
Do not rerun the dump restore or use `--resume-after-restore` just because indexing
timed out. Data repair requires a separate diagnosis and backup; this runbook does
not prescribe deleting records based on a failed indexing attempt.

## 6. Client, HTTPS, and acceptance

Follow [Client deployment](client-image-deployment.md) to enable the released
client. The temporary environment still uses mainnet and the client's `production`
preset; the client's `prerelease` preset targets testnet.

Caddy handles certificate issuance, renewal, and HTTP-to-HTTPS redirects for the
configured domains. It terminates TLS and forwards HTTP over the internal Docker
network. Certificate state persists under `${DATA_ROOT}/caddy-data`. No separate
certificate renewal cron is needed. Check Caddy logs if DNS or certificate setup
fails. Only Caddy's ports should be public; Docker-published ports need review
independently of the host UFW rules.

Before cutover verify:

- Client health returns 204; runtime config has the temporary API and production preset.
- Wallet login/reconnect and expected crews, lots, inventories, agreements, and search work.
- IPFS content loads; a controlled mainnet action updates without a full page reload.
- Browser requests have no CORS, RPC, or WebSocket errors.
- Stack health and convergence stay healthy after deployment.
- [Logs](opentelemetry.md) arrive with host/service labels.
- [Backups](off-host-backups.md) upload, pass integrity checks, and restore in isolation; scheduling and alerts are configured.

## 7. Production handover

Rehearse the handover and record its expected downtime before changing DNS.
Chain catch-up does not copy off-chain changes made on the old deployment since
the dump, including preferences and payment records.

1. Identify all source writers, notifications, payment callbacks, and fulfillment
   jobs. Choose which deployment owns each during the handover.
2. Arrange a final consistent data transfer and verify recovery backups. The
   completed stack has no automated in-place final migration command; plan and
   rehearse this explicitly rather than forcing bootstrap over a live deployment.
3. Complete the [integration checklist](optional-integrations.md), including
   production origins and callback URLs. Avoid duplicate side effects on both hosts.
4. Freeze source writes, transfer the final data, and verify catch-up and browser
   checks before admitting writes on the new deployment.
5. Switch production DNS/origins and the agreed webhook/job ownership; update
   observability environment labels. Account for clients caching old DNS records.
6. Monitor traffic, worker progress, callbacks, and backups. Keep the old system
   available for investigation until acceptance, but prevent it from writing.

After the new deployment accepts writes, pointing DNS back alone is not a safe
data rollback. Any rollback must reconcile those new writes and external effects.
