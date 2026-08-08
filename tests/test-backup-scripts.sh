#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

BIN_DIR="$TEST_ROOT/bin"
AWS_LOG="$TEST_ROOT/aws.log"
DOCKER_LOG="$TEST_ROOT/docker.log"
MANIFEST_COPY="$TEST_ROOT/manifest.json"
CONFIG_FILE="$TEST_ROOT/backup.env"
STATE_DIR="$TEST_ROOT/state"
UPLOAD_DIR="$TEST_ROOT/upload"

mkdir -p \
  "$BIN_DIR" \
  "$STATE_DIR" \
  "$UPLOAD_DIR/backups" \
  "$UPLOAD_DIR/encoded-video" \
  "$UPLOAD_DIR/library/admin" \
  "$UPLOAD_DIR/profile" \
  "$UPLOAD_DIR/thumbs" \
  "$UPLOAD_DIR/upload"
printf 'photo\n' >"$UPLOAD_DIR/library/admin/photo.jpg"
printf 'local DB backup that media sync must exclude\n' >"$UPLOAD_DIR/backups/local.sql.gz"
printf 'generated video\n' >"$UPLOAD_DIR/encoded-video/generated.mp4"
printf 'generated thumbnail\n' >"$UPLOAD_DIR/thumbs/generated.webp"
printf 'avatar\n' >"$UPLOAD_DIR/profile/avatar.jpg"
printf 'queued upload\n' >"$UPLOAD_DIR/upload/video.mov"
touch \
  "$UPLOAD_DIR/backups/.immich" \
  "$UPLOAD_DIR/encoded-video/.immich" \
  "$UPLOAD_DIR/thumbs/.immich"

cat >"$CONFIG_FILE" <<EOF
AWS_PROFILE=test-profile
AWS_REGION=us-east-1
S3_BUCKET=test-immich-backup
AWS_SHARED_CREDENTIALS_FILE=$TEST_ROOT/aws-credentials
COMPOSE_DIR=$REPOSITORY_ROOT
UPLOAD_LOCATION=$UPLOAD_DIR
POSTGRES_CONTAINER=immich_postgres
DB_DATABASE_NAME=immich
DB_USERNAME=postgres
BACKUP_TIMEZONE=America/New_York
STATE_DIR=$STATE_DIR
APT_WAIT_TIMEOUT_SECONDS=5
POSTGRES_WAIT_TIMEOUT_SECONDS=5
EOF

cat >"$BIN_DIR/aws" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$MOCK_AWS_LOG"
printf 'credentials=%s\n' "${AWS_SHARED_CREDENTIALS_FILE:-}" >>"$MOCK_AWS_LOG"

case " $* " in
  *" s3api put-object "*" --key manifests/"*)
    previous=
    for argument in "$@"; do
      if [[ "$previous" == "--body" ]]; then
        cp "$argument" "$MOCK_MANIFEST_COPY"
        break
      fi
      previous=$argument
    done
    ;;
  *" s3api head-object "*)
    if [[ "$*" == *"database/monthly/"* ]]; then
      [[ "${MOCK_MONTHLY_EXISTS:-false}" == true ]]
      exit
    fi
    if [[ "$*" == *" --query Restore "* ]]; then
      printf '%s\n' 'ongoing-request="false"'
    fi
    ;;
  *" s3api list-objects-v2 "*)
    if [[ "$*" == *"database/daily/"* ]]; then
      printf '%s\n' '{"Contents":[{"Key":"database/daily/immich-db-2026-07-18.sql.gz","LastModified":"2026-07-18T08:00:00Z","Size":42,"StorageClass":"STANDARD"}]}'
    else
      printf '%s\n' '{"Contents":[{"Key":"media/library/admin/photo.jpg","LastModified":"2026-07-18T08:00:00Z","Size":42,"StorageClass":"DEEP_ARCHIVE"}]}'
    fi
    ;;
  *" s3api list-object-versions "*)
    if [[ "${MOCK_ALL_YOUNG:-false}" == true ]]; then
      printf '%s\n' '{"Versions":[{"Key":"media/thumbs/young.webp","VersionId":"young-version","LastModified":"2099-01-01T00:00:00Z","Size":5678,"StorageClass":"DEEP_ARCHIVE","IsLatest":true}]}'
    else
      printf '%s\n' '{"Versions":[{"Key":"media/thumbs/generated.webp","VersionId":"generated-version","LastModified":"2020-01-01T00:00:00Z","Size":1234,"StorageClass":"DEEP_ARCHIVE","IsLatest":true},{"Key":"media/thumbs/young.webp","VersionId":"young-version","LastModified":"2099-01-01T00:00:00Z","Size":5678,"StorageClass":"DEEP_ARCHIVE","IsLatest":true}]}'
    fi
    ;;
esac
EOF

cat >"$BIN_DIR/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"

case " $* " in
  *" inspect "*"immich_postgres"*)
    if [[ "${MOCK_POSTGRES_UNHEALTHY_ONCE:-false}" == true && ! -e "$MOCK_HEALTH_MARKER" ]]; then
      : >"$MOCK_HEALTH_MARKER"
      printf '%s\n' unhealthy
    else
      printf '%s\n' healthy
    fi
    ;;
  *" inspect "*"immich_server"*)
    printf '%s\n' ghcr.io/immich-app/immich-server:v3
    ;;
  *" exec "*" pg_dump "*)
    [[ "${MOCK_DUMP_FAIL:-false}" != true ]] || exit 2
    printf '%s\n' 'CREATE TABLE test (id integer);'
    ;;
esac
EOF

cat >"$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF

cat >"$BIN_DIR/fuser" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_APT_ONCE:-false}" == true && ! -e "$MOCK_APT_MARKER" ]]; then
  : >"$MOCK_APT_MARKER"
  exit 0
fi
exit 1
EOF

cat >"$BIN_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod 0755 "$BIN_DIR"/*
export PATH="$BIN_DIR:$PATH"
export MOCK_AWS_LOG="$AWS_LOG"
export MOCK_DOCKER_LOG="$DOCKER_LOG"
export MOCK_MANIFEST_COPY="$MANIFEST_COPY"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local pattern=$2
  grep -F -- "$pattern" "$file" >/dev/null || fail "$file does not contain: $pattern"
}

assert_not_contains() {
  local file=$1
  local pattern=$2
  if grep -F -- "$pattern" "$file" >/dev/null; then
    fail "$file unexpectedly contains: $pattern"
  fi
}

assert_order() {
  local file=$1
  local first=$2
  local second=$3
  local first_line second_line
  first_line=$(grep -n -m1 -F -- "$first" "$file" | cut -d: -f1)
  second_line=$(grep -n -m1 -F -- "$second" "$file" | cut -d: -f1)
  ((first_line < second_line)) || fail "$first did not occur before $second"
}

printf '%s\n' 'Test: successful database-first backup'
"$REPOSITORY_ROOT/scripts/immich-s3-backup.sh" --config "$CONFIG_FILE" >/dev/null
assert_contains "$AWS_LOG" "s3api put-object --bucket test-immich-backup --key database/daily/"
assert_contains "$AWS_LOG" "credentials=$TEST_ROOT/aws-credentials"
assert_contains "$AWS_LOG" "--storage-class STANDARD"
assert_contains "$AWS_LOG" "s3api put-object --bucket test-immich-backup --key database/monthly/"
assert_contains "$AWS_LOG" "--storage-class DEEP_ARCHIVE"
assert_contains "$AWS_LOG" "s3 sync $UPLOAD_DIR/ s3://test-immich-backup/media/"
assert_contains "$AWS_LOG" "--exclude *"
assert_contains "$AWS_LOG" "--include library/*"
assert_contains "$AWS_LOG" "--include upload/*"
assert_contains "$AWS_LOG" "--include profile/*"
assert_not_contains "$AWS_LOG" "--include backups/.immich"
assert_not_contains "$AWS_LOG" "--include thumbs/.immich"
assert_not_contains "$AWS_LOG" "--include encoded-video/.immich"
assert_not_contains "$AWS_LOG" "--include thumbs/*"
assert_not_contains "$AWS_LOG" "--include encoded-video/*"
assert_contains "$AWS_LOG" "--no-follow-symlinks"
assert_not_contains "$AWS_LOG" "--delete"
assert_order "$AWS_LOG" "--key database/daily/" "s3 sync"
jq -e '
  .schema_version == 2
  and .media.policy == "critical-only-v1"
  and .media.critical_paths == ["library/", "upload/", "profile/"]
  and .media.recreated_paths == ["backups/", "thumbs/", "encoded-video/"]
' "$MANIFEST_COPY" >/dev/null || fail "manifest does not describe the critical-only policy"
[[ -f "$STATE_DIR/success-$(TZ=America/New_York date +%F)" ]] || fail "success marker was not written"
[[ ! -e "$STATE_DIR/immich-db-$(TZ=America/New_York date +%F).sql.gz" ]] || fail "completed dump was not cleaned up"

printf '%s\n' 'Test: completed day is idempotent'
line_count=$(wc -l <"$AWS_LOG")
"$REPOSITORY_ROOT/scripts/immich-s3-backup.sh" --config "$CONFIG_FILE" >/dev/null
[[ $(wc -l <"$AWS_LOG") -eq $line_count ]] || fail "completed backup performed additional AWS calls"

printf '%s\n' 'Test: dry run performs no object PUT and writes no success marker'
DRY_STATE="$TEST_ROOT/dry-state"
mkdir "$DRY_STATE"
sed "s#STATE_DIR=$STATE_DIR#STATE_DIR=$DRY_STATE#" "$CONFIG_FILE" >"$TEST_ROOT/dry.env"
: >"$AWS_LOG"
MOCK_MONTHLY_EXISTS=true "$REPOSITORY_ROOT/scripts/immich-s3-backup.sh" \
  --config "$TEST_ROOT/dry.env" --dry-run >/dev/null
assert_contains "$AWS_LOG" "s3 sync"
assert_contains "$AWS_LOG" "--dryrun"
assert_not_contains "$AWS_LOG" "s3api put-object"
[[ -z "$(find "$DRY_STATE" -name 'success-*' -print -quit)" ]] || fail "dry run wrote a success marker"

printf '%s\n' 'Test: failed PostgreSQL dump does not upload'
FAIL_STATE="$TEST_ROOT/fail-state"
mkdir "$FAIL_STATE"
sed "s#STATE_DIR=$STATE_DIR#STATE_DIR=$FAIL_STATE#" "$CONFIG_FILE" >"$TEST_ROOT/fail.env"
: >"$AWS_LOG"
if MOCK_DUMP_FAIL=true "$REPOSITORY_ROOT/scripts/immich-s3-backup.sh" \
  --config "$TEST_ROOT/fail.env" >/dev/null 2>&1; then
  fail "backup unexpectedly succeeded after pg_dump failure"
fi
assert_not_contains "$AWS_LOG" "s3api put-object"
assert_not_contains "$AWS_LOG" "s3 sync"

printf '%s\n' 'Test: backup waits for APT and PostgreSQL health'
WAIT_STATE="$TEST_ROOT/wait-state"
mkdir "$WAIT_STATE"
sed "s#STATE_DIR=$STATE_DIR#STATE_DIR=$WAIT_STATE#" "$CONFIG_FILE" >"$TEST_ROOT/wait.env"
: >"$AWS_LOG"
MOCK_APT_ONCE=true \
MOCK_APT_MARKER="$TEST_ROOT/apt-waited" \
MOCK_POSTGRES_UNHEALTHY_ONCE=true \
MOCK_HEALTH_MARKER="$TEST_ROOT/postgres-waited" \
  "$REPOSITORY_ROOT/scripts/immich-s3-backup.sh" --config "$TEST_ROOT/wait.env" \
  >"$TEST_ROOT/wait-output.log"
assert_contains "$TEST_ROOT/wait-output.log" "Waiting for APT/dpkg activity"
assert_contains "$TEST_ROOT/wait-output.log" "Waiting for PostgreSQL container"
[[ -e "$TEST_ROOT/apt-waited" ]] || fail "APT wait path was not exercised"
[[ -e "$TEST_ROOT/postgres-waited" ]] || fail "PostgreSQL health wait path was not exercised"

printf '%s\n' 'Test: restore inventory, request, status, and staged download'
: >"$AWS_LOG"
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" inventory media/ >/dev/null
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" request --tier Bulk >/dev/null
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" status >/dev/null
RESTORE_DIR="$TEST_ROOT/restore"
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" download "$RESTORE_DIR" >/dev/null
assert_contains "$AWS_LOG" "s3api restore-object"
assert_contains "$AWS_LOG" "GlacierJobParameters"
assert_contains "$AWS_LOG" "--prefix media/library/"
assert_contains "$AWS_LOG" "--prefix media/upload/"
assert_contains "$AWS_LOG" "--prefix media/profile/"
assert_not_contains "$AWS_LOG" "--prefix media/thumbs/"
assert_not_contains "$AWS_LOG" "--prefix media/encoded-video/"
assert_contains "$AWS_LOG" "s3 sync s3://test-immich-backup/media/ $RESTORE_DIR/"
assert_contains "$AWS_LOG" "--exclude *"
assert_contains "$AWS_LOG" "--include library/*"
assert_contains "$AWS_LOG" "--include upload/*"
assert_contains "$AWS_LOG" "--include profile/*"
assert_contains "$AWS_LOG" "s3 cp s3://test-immich-backup/database/daily/"
assert_not_contains "$AWS_LOG" "delete-object"

printf '%s\n' 'Test: generated-asset pruning is dry-run first and bucket-confirmed'
: >"$AWS_LOG"
"$REPOSITORY_ROOT/scripts/immich-s3-prune-generated.sh" \
  --config "$CONFIG_FILE" \
  --admin-profile recovery-admin >"$TEST_ROOT/prune-plan.log"
assert_contains "$AWS_LOG" "--profile recovery-admin"
assert_contains "$AWS_LOG" "s3api list-object-versions"
assert_not_contains "$AWS_LOG" "s3api delete-object"
assert_contains "$TEST_ROOT/prune-plan.log" "Prefix: media/thumbs/"
assert_contains "$TEST_ROOT/prune-plan.log" "eligible=1 bytes=1234 too-young=1"
assert_not_contains "$TEST_ROOT/prune-plan.log" "young-version"
"$REPOSITORY_ROOT/scripts/immich-s3-prune-generated.sh" \
  --config "$CONFIG_FILE" \
  --admin-profile recovery-admin \
  --verbose >"$TEST_ROOT/prune-verbose.log"
assert_contains "$TEST_ROOT/prune-verbose.log" "too-young"
assert_contains "$TEST_ROOT/prune-verbose.log" "young-version"
MOCK_ALL_YOUNG=true "$REPOSITORY_ROOT/scripts/immich-s3-prune-generated.sh" \
  --config "$CONFIG_FILE" \
  --admin-profile recovery-admin >"$TEST_ROOT/prune-none-eligible.log"
assert_contains "$TEST_ROOT/prune-none-eligible.log" "eligible=0 bytes=0 too-young=1"
if "$REPOSITORY_ROOT/scripts/immich-s3-prune-generated.sh" \
  --config "$CONFIG_FILE" \
  --admin-profile recovery-admin \
  --execute \
  --confirm-bucket wrong-bucket >/dev/null 2>&1; then
  fail "prune accepted an incorrect bucket confirmation"
fi
"$REPOSITORY_ROOT/scripts/immich-s3-prune-generated.sh" \
  --config "$CONFIG_FILE" \
  --admin-profile recovery-admin \
  --execute \
  --confirm-bucket test-immich-backup >/dev/null
assert_contains "$AWS_LOG" "sts get-caller-identity"
assert_contains "$AWS_LOG" "s3api delete-object"
assert_contains "$AWS_LOG" "--version-id generated-version"
assert_contains "$AWS_LOG" "--bypass-governance-retention"
assert_not_contains "$AWS_LOG" "--version-id young-version"

printf '%s\n' 'Test: systemd persistence, inhibition, and retry policy'
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.timer" "Persistent=true"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.timer" "WakeSystem=false"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "--what=shutdown:sleep"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "RestartSec=15min"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "StartLimitBurst=4"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "/usr/local/sbin/immich-s3-backup"

printf '%s\n' 'Test: Ansible keeps deployment secrets local and root-owned'
assert_contains "$REPOSITORY_ROOT/.gitignore" "ansible/vars.yml"
assert_contains "$REPOSITORY_ROOT/ansible/roles/immich_s3_backup/tasks/main.yml" "mode: \"0600\""
assert_contains "$REPOSITORY_ROOT/ansible/roles/immich_s3_backup/tasks/main.yml" "no_log: true"
assert_contains "$REPOSITORY_ROOT/ansible/roles/immich_s3_recovery/tasks/apply.yml" "immich_s3_recovery_confirm_apply"
assert_contains "$REPOSITORY_ROOT/ansible/roles/immich_s3_recovery/tasks/regenerate.yml" "thumbnailGeneration"
assert_contains "$REPOSITORY_ROOT/ansible/roles/immich_s3_recovery/tasks/regenerate.yml" "videoConversion"

printf '%s\n' 'All backup and restore script tests passed.'
