# Encrypted off-host backups

`./stack backup` requires a configured Restic repository on your Storage Box.
It does not fall back to local-only backups. Existing automatic backups before
`update` and `upgrade-juno` use the same remote path and fail the operation if the
backup fails.

## Configure the server

Run as the `influence` operator account. Install the host tools:

```sh
sudo apt update
sudo apt install -y restic openssh-client util-linux
```

Generate a dedicated key if you have not already done so (do not overwrite an
existing key):

```sh
ssh-keygen -t ed25519 -f ~/.ssh/influence_backup -C influence-production-backup -N ''
cat ~/.ssh/influence_backup.pub
```

Add the public key to the Storage Box. Enable its SSH access. Add this entry to
`~/.ssh/config`, replacing the hostname and username with your Storage Box details:

```sshconfig
Host influence-backup
    HostName u123456.your-storagebox.de
    User u123456
    Port 23
    IdentityFile ~/.ssh/influence_backup
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 10
```

Protect the configuration and establish host trust interactively:

```sh
chmod 600 ~/.ssh/config ~/.ssh/influence_backup
sftp influence-backup
```

Verify the presented host key fingerprint against Hetzner's published host keys
before accepting it. At the SFTP prompt, run `ls`, then `quit`. Scheduled Restic
connections require key authentication and an already trusted host key; they never
silently accept an unknown key.

From the stack checkout, run `./stack init` to add new configuration defaults to an
existing `.env` without replacing existing values. Set:

```dotenv
BACKUP_REPOSITORY=sftp:influence-backup:influence-production
BACKUP_HOST=influence-production
BACKUP_TAG=influence-production
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
```

Use a dedicated repository directory for this deployment. `BACKUP_HOST` is a stable
snapshot identity, independent of the machine's Linux hostname. The relative
repository path is underneath the Storage Box account's home directory.

Create a strong, unique encryption password in your password manager, then install
it through the hidden prompt:

```sh
./stack install-secret restic_password
./stack backup-init
./stack backup-repository snapshots
```

The password is stored in `secrets/restic_password` with mode 0600, never in `.env`
or container configuration. Keep its recovery copy outside this server: the backup
cannot be decrypted without it. The password file is excluded from snapshots.
`backup-init` is an explicit one-time repository creation; subsequent backups never
initialize repositories automatically.

To check for an existing password without displaying it:

```sh
if [ -s secrets/restic_password ]; then
  stat -c 'Permissions: %a | Owner: %U' secrets/restic_password
else
  echo 'Backup password is missing or empty'
fi
```

Expect mode `600`, owned by `influence`. Once initialized,
`./stack backup-repository snapshots` verifies both remote access and the password.
Do not replace an existing repository's password file with a newly generated value.

## What is saved

Each successful snapshot contains:

- A gzip-compressed MongoDB archive with application writers paused during its creation.
- The stack `.env`, application secrets, Compose files, scripts, and configuration.
- `client.env` when present.
- The configured provisioner signer key when provisioning is enabled.

Juno, Redis, and Elasticsearch data are not copied. Juno can be downloaded again;
the application bootstrap reconstructs derived data from MongoDB. Old Mongo
checkpoints may require a full Juno snapshot during recovery.

A private temporary directory under `${DATA_ROOT}/backups` stages the Mongo dump.
The command checks repository access before pausing writers, resumes them before
upload, then removes the archive only after Restic reports complete success.
The whole backup process is serialized with a host lock. Failed dumps or uploads
retain their staging directories for investigation; monitor local disk space and
remove these only after deciding whether recovery data is needed. They are not
automatically retried or deleted by subsequent backups.

Retention keeps seven daily and four weekly snapshots by default, scoped to the
configured host and tag. Multiple snapshots can satisfy both rules. Restic prunes
unreferenced data after a successful upload; a retention failure still makes the
command fail even though the new snapshot has been uploaded. Do not budget for
large deduplication savings between gzip archives.

Retention runs as part of every successful `./stack backup`; no separate deletion
cron is needed. Seven daily plus four weekly is not necessarily eleven snapshots:
one snapshot can satisfy both rules. Host/tag identity should remain stable so the
policy continues to cover the intended snapshots. Do not manually delete repository
files through SFTP. Preview the default policy without deleting anything:

```sh
./stack backup-repository forget --host influence-production --tag influence-production \
  --group-by host,tags --keep-daily 7 --keep-weekly 4 --dry-run
```

Substitute your configured host, tag, and retention counts if different. Size the
repository from actual snapshot growth, with room for a new upload before pruning.

## Enable the daily schedule

First, after MongoDB has been restored and the stack is operational, run:

```sh
./stack backup
./stack backup-repository snapshots
./stack backup-repository check
```

The supplied service assumes user/group `influence` and checkout
`/home/influence/influence-stack`. Edit the installed service before enabling the
timer if yours differs:

```sh
sudo install -m 0644 config/systemd/influence-backup.service /etc/systemd/system/
sudo install -m 0644 config/systemd/influence-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now influence-backup.timer
systemctl list-timers influence-backup.timer
```

Backups run daily at 03:00 UTC with up to 15 minutes of jitter. Persistent scheduling
runs a missed backup after the host comes back online. The service runs as the
operator, using that account's SSH configuration and Docker group access.

Inspect failures and output with:

```sh
systemctl status influence-backup.service
journalctl -u influence-backup.service --since yesterday
```

Failures produce a nonzero service status and journal entry. No email or external
alert delivery is configured by these units; connect service failure and backup
freshness monitoring to your alerting provider before relying on unattended runs.

## Restore and verify

Periodically run `./stack backup-repository check --read-data` to verify all stored
data, and perform an actual Mongo restore test separately. Repository integrity is
not a substitute for testing application recovery.

List snapshots and inspect a selected snapshot's file paths:

```sh
./stack backup-repository snapshots
./stack backup-repository ls SNAPSHOT_ID
```

Restore into a new private directory, never over live production files:

```sh
umask 077
mkdir -p /home/influence/backup-restore
./stack backup-repository restore SNAPSHOT_ID --target /home/influence/backup-restore
```

Absolute original paths appear beneath that target. Locate `influence.archive`
inside the restored `influencedata/backups/pending.*` directory and supply its path
to bootstrap on a fresh recovery deployment. Review restored configuration/secrets
before installing them. Recover the encryption password and SSH access independently
if the original server is lost; install Restic and reconnect to the same repository
without running `backup-init` again.

### Test the Mongo archive in isolation

After restoring files into the private directory above, set `archive` to the
actual restored archive path. This test uses a disposable Mongo container with no
network access or published ports, and never connects to the live database:

```sh
archive=/home/influence/backup-restore/influencedata/backups/pending.REPLACE/influence.archive
test -s "$archive"
mongo_image="$(docker compose -f compose.yaml config --format json | jq -r '.services.mongo.image')"
docker run -d --name influence-restore-check --network none \
  --mount "type=bind,src=$archive,dst=/restore/influence.archive,readonly" \
  "$mongo_image"
docker logs --tail=30 influence-restore-check
docker exec influence-restore-check mongosh --quiet --eval 'db.adminCommand({ping: 1})'
```

Wait for a successful ping before continuing. Restore the application database
(replace `influence` if `MONGO_DATABASE` differs):

```sh
docker exec influence-restore-check mongorestore \
  --archive=/restore/influence.archive --gzip --nsInclude='influence.*' --stopOnError
docker exec influence-restore-check mongosh --quiet influence \
  --eval 'db.getCollectionNames().sort().forEach(n => print(n + ": " + db.getCollection(n).countDocuments({})))'
```

Require a nonzero restored document count, zero failures, and expected application
collections. Counts may take time. This verifies archive restoration; full disaster
recovery also requires rehearsing bootstrap and application checks on a separate
host, including Juno checkpoint availability.

When finished, remove only this disposable container and its anonymous volumes:

```sh
docker rm -fv influence-restore-check
```

The restored files include secrets. Keep their directory private and remove it
when the recovery exercise is complete.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| `Required command not found: restic` | Install the host packages listed at the start of this guide. |
| SSH or repository access fails | Test `sftp influence-backup` as the operator; check key, host trust, username, and repository path. |
| Password file missing or repository cannot be decrypted | Recover the existing encryption password from its external recovery copy. |
| Mongo URI selects `admin` but `--db` selects `influence` | Update the checkout: backup must use `/?authSource=admin` with the data database selected separately. |
| Dump or upload fails | Check logs and writer status. The failure handler attempts to unpause writers. Failed staging directories remain under `${DATA_ROOT}/backups`; inspect before removing them. |
| Retention fails after upload | Confirm the new snapshot exists, investigate the failure, and retry the retention policy. An uploaded snapshot can exist even though the overall command failed. |

`check` validates repository structure; `check --read-data` also reads stored data.
Neither replaces a Mongo restore test. Keep the Restic password and SSH recovery
access outside the server; the password is deliberately excluded from snapshots.
