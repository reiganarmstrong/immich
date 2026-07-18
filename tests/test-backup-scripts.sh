#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

BIN_DIR="$TEST_ROOT/bin"
AWS_LOG="$TEST_ROOT/aws.log"
DOCKER_LOG="$TEST_ROOT/docker.log"
CONFIG_FILE="$TEST_ROOT/backup.env"
STATE_DIR="$TEST_ROOT/state"
UPLOAD_DIR="$TEST_ROOT/upload"

mkdir -p "$BIN_DIR" "$STATE_DIR" "$UPLOAD_DIR/backups" "$UPLOAD_DIR/library/admin"
printf 'photo\n' >"$UPLOAD_DIR/library/admin/photo.jpg"
printf 'local DB backup that media sync must exclude\n' >"$UPLOAD_DIR/backups/local.sql.gz"

cat >"$CONFIG_FILE" <<EOF
AWS_PROFILE=test-profile
AWS_REGION=us-east-1
S3_BUCKET=test-immich-backup
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

case " $* " in
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
assert_contains "$AWS_LOG" "--storage-class STANDARD"
assert_contains "$AWS_LOG" "s3api put-object --bucket test-immich-backup --key database/monthly/"
assert_contains "$AWS_LOG" "--storage-class DEEP_ARCHIVE"
assert_contains "$AWS_LOG" "s3 sync $UPLOAD_DIR/ s3://test-immich-backup/media/"
assert_contains "$AWS_LOG" "--exclude backups/*"
assert_contains "$AWS_LOG" "--include backups/.immich"
assert_contains "$AWS_LOG" "--no-follow-symlinks"
assert_not_contains "$AWS_LOG" "--delete"
assert_order "$AWS_LOG" "--key database/daily/" "s3 sync"
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
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" request --tier Bulk media/ >/dev/null
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" status media/ >/dev/null
RESTORE_DIR="$TEST_ROOT/restore"
"$REPOSITORY_ROOT/scripts/immich-s3-restore.sh" --config "$CONFIG_FILE" download "$RESTORE_DIR" >/dev/null
assert_contains "$AWS_LOG" "s3api restore-object"
assert_contains "$AWS_LOG" "GlacierJobParameters"
assert_contains "$AWS_LOG" "s3 sync s3://test-immich-backup/media/ $RESTORE_DIR/"
assert_contains "$AWS_LOG" "s3 cp s3://test-immich-backup/database/daily/"
assert_not_contains "$AWS_LOG" "delete-object"

printf '%s\n' 'Test: systemd persistence, inhibition, and retry policy'
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.timer" "Persistent=true"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.timer" "WakeSystem=false"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "--what=shutdown:sleep"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "RestartSec=15min"
assert_contains "$REPOSITORY_ROOT/systemd/immich-s3-backup.service" "StartLimitBurst=4"

printf '%s\n' 'All backup and restore script tests passed.'
