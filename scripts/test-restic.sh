#!/bin/sh
# Run in an ephemeral Restic container; no production repository is accessed.
set -eu
export RESTIC_REPOSITORY=/tmp/repository
export RESTIC_PASSWORD=test-only-encryption-password
mkdir -p /tmp/source/secrets
printf 'database fixture\n' > /tmp/source/influence.archive
printf 'application secret\n' > /tmp/source/secrets/mongo_password
printf 'excluded encryption key\n' > /tmp/source/secrets/restic_password
restic init
restic backup --host influence-production --tag influence-production \
  --exclude /tmp/source/secrets/restic_password /tmp/source
restic check --read-data
restic restore latest --target /tmp/restore
cmp /tmp/source/influence.archive /tmp/restore/tmp/source/influence.archive
cmp /tmp/source/secrets/mongo_password /tmp/restore/tmp/source/secrets/mongo_password
[ ! -e /tmp/restore/tmp/source/secrets/restic_password ]
restic forget --host influence-production --tag influence-production \
  --group-by host,tags --keep-daily 7 --keep-weekly 4 --prune
printf 'Encrypted repository restore and exclusion checks passed\n'
