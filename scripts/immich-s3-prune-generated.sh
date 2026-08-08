#!/usr/bin/env bash

set -Eeuo pipefail

CONFIG_FILE="${IMMICH_S3_BACKUP_CONFIG:-/etc/immich-s3-backup.env}"
ADMIN_PROFILE=
ADMIN_CREDENTIALS_FILE=
ADMIN_CONFIG_FILE=
CONFIRM_BUCKET=
EXECUTE=false
VERBOSE=false
MINIMUM_AGE_DAYS=180

usage() {
  cat <<'EOF'
Usage:
  immich-s3-prune-generated.sh [--config PATH] --admin-profile PROFILE
    [--admin-credentials-file PATH] [--admin-config-file PATH]
    [--verbose] [--execute --confirm-bucket BUCKET]

Plans permanent deletion of Deep Archive versions under media/thumbs/ and
media/encoded-video/ once each version is at least 180 days old. The default
is read-only. Execution requires an administrative profile that can delete
object versions and bypass governance retention; the backup profile cannot.
Use --verbose to print one line per version in addition to prefix summaries.
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
    --admin-profile)
      (($# >= 2)) || die "--admin-profile requires a profile name"
      ADMIN_PROFILE=$2
      shift 2
      ;;
    --admin-credentials-file)
      (($# >= 2)) || die "--admin-credentials-file requires a path"
      ADMIN_CREDENTIALS_FILE=$2
      shift 2
      ;;
    --admin-config-file)
      (($# >= 2)) || die "--admin-config-file requires a path"
      ADMIN_CONFIG_FILE=$2
      shift 2
      ;;
    --execute)
      EXECUTE=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --confirm-bucket)
      (($# >= 2)) || die "--confirm-bucket requires a bucket name"
      CONFIRM_BUCKET=$2
      shift 2
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

: "${AWS_REGION:?AWS_REGION is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
[[ -n "$ADMIN_PROFILE" ]] || die "--admin-profile is required"
[[ "$ADMIN_PROFILE" =~ ^[A-Za-z0-9_.@+-]+$ ]] || die "invalid admin profile name"

if [[ "$EXECUTE" == true ]]; then
  [[ "$CONFIRM_BUCKET" == "$S3_BUCKET" ]] \
    || die "--confirm-bucket must exactly match $S3_BUCKET when using --execute"
fi

for command_name in aws base64 date jq; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done

unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
if [[ -n "$ADMIN_CREDENTIALS_FILE" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE=$ADMIN_CREDENTIALS_FILE
fi
if [[ -n "$ADMIN_CONFIG_FILE" ]]; then
  export AWS_CONFIG_FILE=$ADMIN_CONFIG_FILE
fi

aws_cli=(aws --profile "$ADMIN_PROFILE" --region "$AWS_REGION" --no-cli-pager)
cutoff_epoch=$(date -u -d "-$MINIMUM_AGE_DAYS days" +%s)
eligible_count=0
eligible_bytes=0
young_count=0

if [[ "$EXECUTE" == true ]]; then
  "${aws_cli[@]}" sts get-caller-identity >/dev/null
fi

for prefix in media/thumbs/ media/encoded-video/; do
  version_list=$("${aws_cli[@]}" s3api list-object-versions \
    --bucket "$S3_BUCKET" \
    --prefix "$prefix" \
    --output json)

  prefix_stats=$(jq -c --argjson cutoff "$cutoff_epoch" '
    def version_epoch:
      (.last_modified | sub("\\+00:00$"; "Z") | fromdateiso8601);
    [
      (.Versions[]? | {
        key: .Key,
        version_id: .VersionId,
        last_modified: .LastModified,
        size: .Size,
        delete_marker: false
      }),
      (.DeleteMarkers[]? | {
        key: .Key,
        version_id: .VersionId,
        last_modified: .LastModified,
        size: 0,
        delete_marker: true
      })
    ] as $items
    | {
        eligible: ([$items[] | select(version_epoch <= $cutoff)] | length),
        eligible_bytes: ([$items[] | select(version_epoch <= $cutoff) | .size] | add // 0),
        young: ([$items[] | select(version_epoch > $cutoff)] | length)
      }
  ' <<<"$version_list")
  prefix_eligible=$(jq -r '.eligible' <<<"$prefix_stats")
  prefix_eligible_bytes=$(jq -r '.eligible_bytes' <<<"$prefix_stats")
  prefix_young=$(jq -r '.young' <<<"$prefix_stats")
  eligible_count=$((eligible_count + prefix_eligible))
  eligible_bytes=$((eligible_bytes + prefix_eligible_bytes))
  young_count=$((young_count + prefix_young))

  printf 'Prefix: %s eligible=%d bytes=%d too-young=%d\n' \
    "$prefix" \
    "$prefix_eligible" \
    "$prefix_eligible_bytes" \
    "$prefix_young"

  if [[ "$VERBOSE" == true ]]; then
    jq -r --argjson cutoff "$cutoff_epoch" '
      def version_epoch:
        (.last_modified | sub("\\+00:00$"; "Z") | fromdateiso8601);
      [
        (.Versions[]? | {
          key: .Key,
          version_id: .VersionId,
          last_modified: .LastModified
        }),
        (.DeleteMarkers[]? | {
          key: .Key,
          version_id: .VersionId,
          last_modified: .LastModified
        })
      ]
      | .[]
      | [
          (if version_epoch <= $cutoff then "eligible" else "too-young" end),
          .last_modified,
          .version_id,
          .key
        ]
      | @tsv
    ' <<<"$version_list"
  fi

  [[ "$EXECUTE" == true && "$prefix_eligible" -gt 0 ]] || continue

  while IFS= read -r encoded_item; do
    [[ -n "$encoded_item" ]] || continue
    item=$(printf '%s' "$encoded_item" | base64 --decode)
    key=$(jq -r '.key' <<<"$item")
    version_id=$(jq -r '.version_id' <<<"$item")
    last_modified=$(jq -r '.last_modified' <<<"$item")
    delete_marker=$(jq -r '.delete_marker' <<<"$item")

    if [[ "$VERBOSE" == true ]]; then
      printf 'deleting\t%s\t%s\t%s\n' "$last_modified" "$version_id" "$key"
    fi

    delete_args=(
      s3api delete-object
      --bucket "$S3_BUCKET"
      --key "$key"
      --version-id "$version_id"
    )
    if [[ "$delete_marker" == false ]]; then
      delete_args+=(--bypass-governance-retention)
    fi
    "${aws_cli[@]}" "${delete_args[@]}" >/dev/null
  done < <(
    jq -r --argjson cutoff "$cutoff_epoch" '
      def version_epoch:
        (.last_modified | sub("\\+00:00$"; "Z") | fromdateiso8601);
      [
        (.Versions[]? | {
          key: .Key,
          version_id: .VersionId,
          last_modified: .LastModified,
          size: .Size,
          delete_marker: false
        }),
        (.DeleteMarkers[]? | {
          key: .Key,
          version_id: .VersionId,
          last_modified: .LastModified,
          size: 0,
          delete_marker: true
        })
      ]
      | .[]
      | select(version_epoch <= $cutoff)
      | @base64
    ' <<<"$version_list"
  )
done

printf 'Summary: eligible=%d bytes=%d too-young=%d mode=%s\n' \
  "$eligible_count" \
  "$eligible_bytes" \
  "$young_count" \
  "$([[ "$EXECUTE" == true ]] && printf execute || printf plan)"

if [[ "$EXECUTE" == false && "$eligible_count" -gt 0 ]]; then
  printf 'No objects were deleted. Review the plan, then rerun with --execute and --confirm-bucket.\n'
fi
