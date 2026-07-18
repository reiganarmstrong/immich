#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="${IMMICH_S3_BACKUP_CONFIG:-/etc/immich-s3-backup.env}"

usage() {
  cat <<'EOF'
Usage:
  immich-s3-restore.sh [--config PATH] inventory [PREFIX]
  immich-s3-restore.sh [--config PATH] request [--tier Bulk|Standard] [PREFIX]
  immich-s3-restore.sh [--config PATH] status [PREFIX]
  immich-s3-restore.sh [--config PATH] download DESTINATION [DATABASE_KEY]

Commands:
  inventory  List current objects and their storage classes.
  request    Initiate restore requests for archived objects (default: media/).
  status     Show archive restore status (default: media/).
  download   Download restored media plus a selected or latest daily DB dump.

The download destination must be empty. This script never writes to the live
Immich upload root automatically.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --config)
      (($# >= 2)) || die "--config requires a path"
      CONFIG_FILE=$2
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

[[ -r "$CONFIG_FILE" ]] || die "configuration file is not readable: $CONFIG_FILE"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"

for command_name in aws base64 find jq mkdir; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

(($# > 0)) || {
  usage
  exit 1
}

command_name=$1
shift
aws_cli=(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager)

list_objects() {
  local prefix=$1
  "${aws_cli[@]}" s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix" --output json
}

case "$command_name" in
  inventory)
    prefix=${1:-}
    list_objects "$prefix" \
      | jq -r '.Contents[]? | [.LastModified, (.StorageClass // "STANDARD"), (.Size | tostring), .Key] | @tsv'
    ;;

  request)
    tier=Bulk
    if [[ "${1:-}" == "--tier" ]]; then
      (($# >= 2)) || die "--tier requires Bulk or Standard"
      tier=$2
      shift 2
    fi
    [[ "$tier" == "Bulk" || "$tier" == "Standard" ]] || die "tier must be Bulk or Standard"
    prefix=${1:-media/}
    object_list=$(list_objects "$prefix")

    requested=0
    while IFS= read -r encoded_key; do
      [[ -n "$encoded_key" ]] || continue
      key=$(printf '%s' "$encoded_key" | base64 --decode)
      if output=$("${aws_cli[@]}" s3api restore-object \
        --bucket "$S3_BUCKET" \
        --key "$key" \
        --restore-request "{\"Days\":7,\"GlacierJobParameters\":{\"Tier\":\"$tier\"}}" 2>&1); then
        printf 'requested\t%s\n' "$key"
      elif [[ "$output" == *RestoreAlreadyInProgress* || "$output" == *ObjectAlreadyInActiveTierError* ]]; then
        printf 'already-active\t%s\n' "$key"
      else
        printf '%s\n' "$output" >&2
        die "restore request failed for $key"
      fi
      ((requested += 1))
    done < <(jq -r '.Contents[]? | select(.StorageClass == "DEEP_ARCHIVE" or .StorageClass == "GLACIER") | .Key | @base64' <<<"$object_list")
    printf 'Processed %d archived objects under %s\n' "$requested" "$prefix"
    ;;

  status)
    prefix=${1:-media/}
    object_list=$(list_objects "$prefix")
    while IFS= read -r encoded_key; do
      [[ -n "$encoded_key" ]] || continue
      key=$(printf '%s' "$encoded_key" | base64 --decode)
      restore=$("${aws_cli[@]}" s3api head-object \
        --bucket "$S3_BUCKET" \
        --key "$key" \
        --query 'Restore' \
        --output text 2>/dev/null || true)
      case "$restore" in
        *'ongoing-request="false"'*) state=ready ;;
        *'ongoing-request="true"'*) state=in-progress ;;
        *) state=not-requested ;;
      esac
      printf '%s\t%s\n' "$state" "$key"
    done < <(jq -r '.Contents[]? | select(.StorageClass == "DEEP_ARCHIVE" or .StorageClass == "GLACIER") | .Key | @base64' <<<"$object_list")
    ;;

  download)
    (($# >= 1)) || die "download requires an empty destination"
    destination=$1
    database_key=${2:-}

    if [[ -e "$destination" ]]; then
      [[ -d "$destination" ]] || die "destination is not a directory: $destination"
      [[ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || die "destination must be empty: $destination"
    else
      mkdir -p "$destination"
    fi
    mkdir -p "$destination/backups"

    if [[ -z "$database_key" ]]; then
      database_key=$(list_objects "database/daily/" \
        | jq -r '.Contents // [] | sort_by(.LastModified) | last | .Key // empty')
      [[ -n "$database_key" ]] || die "no daily database backup is available"
    fi

    "${aws_cli[@]}" s3 sync \
      "s3://$S3_BUCKET/media/" \
      "$destination/" \
      --force-glacier-transfer \
      --only-show-errors

    "${aws_cli[@]}" s3 cp \
      "s3://$S3_BUCKET/$database_key" \
      "$destination/backups/" \
      --force-glacier-transfer \
      --only-show-errors

    printf 'Downloaded media and %s to %s\n' "$database_key" "$destination"
    ;;

  *)
    usage
    die "unknown command: $command_name"
    ;;
esac
