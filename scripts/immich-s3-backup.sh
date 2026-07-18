#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="${IMMICH_S3_BACKUP_CONFIG:-/etc/immich-s3-backup.env}"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: immich-s3-backup.sh [--config PATH] [--dry-run]

Creates a fresh PostgreSQL dump, uploads daily/monthly recovery points, and
incrementally syncs the Immich upload root to S3 Glacier Deep Archive.
EOF
}

log() {
  printf '%s %s\n' "$(date --iso-8601=seconds)" "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --config)
      (($# >= 2)) || die "--config requires a path"
      CONFIG_FILE=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "configuration file is not readable: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${COMPOSE_DIR:?COMPOSE_DIR is required}"
: "${UPLOAD_LOCATION:?UPLOAD_LOCATION is required}"
: "${POSTGRES_CONTAINER:?POSTGRES_CONTAINER is required}"
: "${DB_DATABASE_NAME:?DB_DATABASE_NAME is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"

# These optional AWS SDK variables can be supplied by the Ansible-managed
# configuration. Export them because this file is also sourced during manual
# invocations outside systemd.
[[ -z "${AWS_SHARED_CREDENTIALS_FILE:-}" ]] || export AWS_SHARED_CREDENTIALS_FILE
[[ -z "${AWS_CONFIG_FILE:-}" ]] || export AWS_CONFIG_FILE

BACKUP_TIMEZONE=${BACKUP_TIMEZONE:-America/New_York}
STATE_DIR=${STATE_DIR:-/var/lib/immich-s3-backup}
APT_WAIT_TIMEOUT_SECONDS=${APT_WAIT_TIMEOUT_SECONDS:-7200}
POSTGRES_WAIT_TIMEOUT_SECONDS=${POSTGRES_WAIT_TIMEOUT_SECONDS:-900}

for command_name in aws date docker flock fuser git gzip install jq stat systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

[[ -d "$COMPOSE_DIR" ]] || die "Compose directory does not exist: $COMPOSE_DIR"
[[ -r "$UPLOAD_LOCATION" && -x "$UPLOAD_LOCATION" ]] || die "upload root is not readable: $UPLOAD_LOCATION"

install -d -m 0700 "$STATE_DIR"
exec 9>"$STATE_DIR/backup.lock"
flock -n 9 || die "another Immich S3 backup is already running"

local_date=$(TZ="$BACKUP_TIMEZONE" date +%F)
local_month=$(TZ="$BACKUP_TIMEZONE" date +%Y-%m)
success_marker="$STATE_DIR/success-$local_date"
dump_file="$STATE_DIR/immich-db-$local_date.sql.gz"
daily_key="database/daily/immich-db-$local_date.sql.gz"
monthly_key="database/monthly/immich-db-$local_month.sql.gz"
manifest_file="$STATE_DIR/manifest-$local_date.json"
manifest_key="manifests/$local_date.json"

if [[ -s "$success_marker" && "$DRY_RUN" == false ]]; then
  log "Backup already completed for $local_date"
  exit 0
fi

aws_cli=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager)

wait_for_apt() {
  local deadline=$((SECONDS + APT_WAIT_TIMEOUT_SECONDS))

  while systemctl is-active --quiet apt-daily.service \
    || systemctl is-active --quiet apt-daily-upgrade.service \
    || fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "timed out waiting for APT/dpkg activity to finish"
    log "Waiting for APT/dpkg activity to finish"
    sleep 30
  done
}

wait_for_postgres() {
  local deadline=$((SECONDS + POSTGRES_WAIT_TIMEOUT_SECONDS))
  local health

  while true; do
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$POSTGRES_CONTAINER" 2>/dev/null || true)
    if [[ "$health" == "healthy" || "$health" == "running" ]]; then
      return
    fi
    ((SECONDS < deadline)) || die "timed out waiting for $POSTGRES_CONTAINER to become healthy"
    log "Waiting for PostgreSQL container (current status: ${health:-missing})"
    sleep 15
  done
}

create_database_dump() {
  local temporary_dump

  if [[ -s "$dump_file" ]] && gzip -t "$dump_file"; then
    log "Reusing validated in-progress database dump: $dump_file"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would create PostgreSQL dump at $dump_file"
    return
  fi

  temporary_dump=$(mktemp "$STATE_DIR/.immich-db-$local_date.XXXXXX.sql.gz")

  log "Creating PostgreSQL dump before media upload"
  if ! docker exec "$POSTGRES_CONTAINER" pg_dump \
      --clean \
      --if-exists \
      --dbname="$DB_DATABASE_NAME" \
      --username="$DB_USERNAME" \
      | gzip --rsyncable >"$temporary_dump"; then
    rm -f -- "$temporary_dump"
    die "PostgreSQL dump failed"
  fi

  if ! gzip -t "$temporary_dump"; then
    rm -f -- "$temporary_dump"
    die "new PostgreSQL dump failed gzip validation"
  fi
  chmod 0600 "$temporary_dump"
  mv "$temporary_dump" "$dump_file"
}

put_locked_object() {
  local source_file=$1
  local key=$2
  local storage_class=$3
  local retention_days=$4
  local retain_until

  retain_until=$(date -u -d "+$retention_days days" +%Y-%m-%dT%H:%M:%SZ)

  if [[ "$DRY_RUN" == true ]]; then
    log "DRY RUN: would upload $source_file to s3://$S3_BUCKET/$key ($storage_class, governance retention $retention_days days)"
    return
  fi

  "${aws_cli[@]}" s3api put-object \
    --bucket "$S3_BUCKET" \
    --key "$key" \
    --body "$source_file" \
    --storage-class "$storage_class" \
    --server-side-encryption AES256 \
    --checksum-algorithm SHA256 \
    --object-lock-mode GOVERNANCE \
    --object-lock-retain-until-date "$retain_until" >/dev/null
}

object_exists() {
  "${aws_cli[@]}" s3api head-object --bucket "$S3_BUCKET" --key "$1" >/dev/null 2>&1
}

wait_for_apt
wait_for_postgres

log "Validating AWS identity and backup bucket access"
"${aws_cli[@]}" sts get-caller-identity >/dev/null
"${aws_cli[@]}" s3api get-bucket-location --bucket "$S3_BUCKET" >/dev/null

create_database_dump
put_locked_object "$dump_file" "$daily_key" STANDARD 30

monthly_created=false
if object_exists "$monthly_key"; then
  log "Monthly recovery point already exists: s3://$S3_BUCKET/$monthly_key"
else
  put_locked_object "$dump_file" "$monthly_key" DEEP_ARCHIVE 365
  monthly_created=true
fi

log "Incrementally syncing Immich files to Deep Archive"
sync_args=(
  s3 sync
  "$UPLOAD_LOCATION/"
  "s3://$S3_BUCKET/media/"
  --exclude "backups/*"
  --include "backups/.immich"
  --storage-class DEEP_ARCHIVE
  --sse AES256
  --checksum-algorithm SHA256
  --no-follow-symlinks
  --only-show-errors
)
if [[ "$DRY_RUN" == true ]]; then
  sync_args+=(--dryrun)
fi
"${aws_cli[@]}" "${sync_args[@]}"

immich_image=$(docker inspect --format '{{.Config.Image}}' immich_server 2>/dev/null || printf 'unknown')
git_revision=$(git -C "$COMPOSE_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')
completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
dump_size=$(if [[ -f "$dump_file" ]]; then stat -c %s "$dump_file"; else printf '0'; fi)

jq -n \
  --arg completed_at "$completed_at" \
  --arg local_date "$local_date" \
  --arg timezone "$BACKUP_TIMEZONE" \
  --arg daily_key "$daily_key" \
  --arg monthly_key "$monthly_key" \
  --arg immich_image "$immich_image" \
  --arg git_revision "$git_revision" \
  --argjson dump_size "$dump_size" \
  --argjson monthly_created "$monthly_created" \
  '{
    schema_version: 1,
    completed_at: $completed_at,
    backup_date: $local_date,
    timezone: $timezone,
    database: {
      daily_key: $daily_key,
      monthly_key: $monthly_key,
      monthly_created: $monthly_created,
      compressed_bytes: $dump_size
    },
    media_prefix: "media/",
    immich_image: $immich_image,
    git_revision: $git_revision
  }' >"$manifest_file"

put_locked_object "$manifest_file" "$manifest_key" STANDARD 30

if [[ "$DRY_RUN" == true ]]; then
  rm -f -- "$manifest_file"
  log "Dry run completed; no S3 objects or success marker were written"
  exit 0
fi

temporary_success=$(mktemp "$STATE_DIR/.success-$local_date.XXXXXX")
printf '%s\n' "$completed_at" >"$temporary_success"
chmod 0600 "$temporary_success"
mv "$temporary_success" "$success_marker"
rm -f -- "$dump_file" "$manifest_file"
log "Backup completed successfully for $local_date"
