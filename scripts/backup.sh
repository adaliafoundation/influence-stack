#!/usr/bin/env bash

prepare_backup_repository() {
  require_command restic
  require_command ssh
  [[ "${BACKUP_REPOSITORY:-}" == sftp:* ]] \
    || die "BACKUP_REPOSITORY must specify an off-host sftp: Restic repository"
  validate_secret_file restic_password || die "Install the Restic encryption password first"
  local variable
  for variable in BACKUP_HOST BACKUP_TAG; do
    [[ "${!variable:-}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid $variable"
  done
  for variable in BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY; do
    [[ "${!variable:-}" =~ ^[1-9][0-9]*$ ]] || die "$variable must be a positive integer"
  done
}

backup_restic() {
  restic --repo "$BACKUP_REPOSITORY" --password-file "$(secret_file restic_password)" \
    -o 'sftp.args=-oBatchMode=yes -oStrictHostKeyChecking=yes' "$@"
}

backup_repository() {
  [ "$#" -gt 0 ] || die "Usage: ./stack backup-repository RESTIC_ARGS..."
  load_env
  prepare_backup_repository
  backup_restic "$@"
}
