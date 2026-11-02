#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BASM_ROOT="$TEMP/live"
BACKUP_LOCATION="$TEMP/backups"
BASM_CONTAINER_PREFIX=basm-test
RESTIC_PASSWORD=test-only-repository-password
SHARE_STATE=root
FAIL_CHECK=false
CHANGE_DURING_CHECK=false
CALLS="$TEMP/restic-calls"
mkdir -p "$BASM_ROOT/config"
printf 'important application data\n' > "$BASM_ROOT/data"
findmnt() {
  case "$SHARE_STATE" in
    root) printf '{"filesystems":[{"target":"/","uuid":"guest-root"}]}\n' ;;
    external|same-device) jq -nc --arg target "$BACKUP_LOCATION" \
      '{filesystems:[{target:$target,source:"basm-backup",uuid:null}]}' ;;
    changed) jq -nc --arg target "$BACKUP_LOCATION" \
      '{filesystems:[{target:$target,source:"other-backup",uuid:null}]}' ;;
    malformed) printf '{"filesystems":[]}\n' ;;
    *) return 1 ;;
  esac
}
stat() {
  if [[ "$1" == -c && "$2" == %d ]]; then
    if [[ "$SHARE_STATE" != root && "$SHARE_STATE" != same-device && "$3" == "$BACKUP_LOCATION" ]]; then
      printf '200\n'
    else
      printf '100\n'
    fi
  else
    command stat "$@"
  fi
}
restic() {
  printf '%s\n' "$*" >> "$CALLS"
  if [[ "$*" == 'check --read-data' ]]; then
    [[ "$FAIL_CHECK" == false ]] || return 1
    if [[ "$CHANGE_DURING_CHECK" == true ]]; then SHARE_STATE=changed; fi
  fi
  command "${RESTIC_BIN:-restic}" "$@"
}
expect_failure() {
  local result
  set +e
  ("$@") > "$TEMP/expected-failure.log" 2>&1
  result=$?
  set -e
  if (( result == 0 )); then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi
}
initialize_repository
restic_command backup --host "$BASM_CONTAINER_PREFIX" --tag basm-v2 "$BASM_ROOT"
restic_command snapshots --json > "$TEMP/original-snapshots.json"
cp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
(
  BACKUP_LOCATION="$TEMP/missing/mount/backups"
  SHARE_STATE=changed
  expect_failure initialize_repository
  [[ ! -e "$TEMP/missing" ]]
)
expect_failure adopt_backup_mount
SHARE_STATE=same-device expect_failure adopt_backup_mount
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
SHARE_STATE=external
expect_failure restic_command snapshots
FAIL_CHECK=true expect_failure adopt_backup_mount
grep -q 'check --read-data' "$CALLS"
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
RESTIC_PASSWORD=wrong-password expect_failure adopt_backup_mount
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
SHARE_STATE=malformed expect_failure adopt_backup_mount
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
pack="$(find "$BACKUP_LOCATION/restic/data" -type f -print -quit)"
mv "$pack" "$TEMP/held-pack"
expect_failure adopt_backup_mount
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
mv "$TEMP/held-pack" "$pack"
CHANGE_DURING_CHECK=true expect_failure adopt_backup_mount
grep -q 'changed during verification' "$TEMP/expected-failure.log"
cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
(
  BACKUP_LOCATION="$TEMP/foreign"
  mkdir "$BACKUP_LOCATION"
  restic_repository_command init
  restic_repository_command backup --host other-deployment --tag basm-v2 "$BASM_ROOT"
  expect_failure adopt_backup_mount
  grep -q 'No complete snapshot for this deployment' "$TEMP/expected-failure.log"
  cmp "$BASM_ROOT/config/backup-device" "$TEMP/original-device"
)
(
  BACKUP_LOCATION="$TEMP/empty"
  mkdir "$BACKUP_LOCATION"
  restic_repository_command init
  expect_failure adopt_backup_mount
  grep -q 'No complete snapshot for this deployment' "$TEMP/expected-failure.log"
)
adopt_backup_mount
restic_command snapshots --json > "$TEMP/adopted-snapshots.json"
cmp "$TEMP/original-snapshots.json" "$TEMP/adopted-snapshots.json"
[[ "$(stat -c %a "$BASM_ROOT/config/backup-device")" == 600 ]]
previous=("$BASM_ROOT/config/backup-device.before-adopt."*)
[[ ${#previous[@]} == 1 ]]
cmp "$TEMP/original-device" "${previous[0]}"
SHARE_STATE=root expect_failure restic_command snapshots
SHARE_STATE=changed expect_failure restic_command snapshots
SHARE_STATE=missing expect_failure initialize_repository
restic_command check --read-data
(
  cli="$TEMP/cli"
  mkdir -p "$cli/bin" "$cli/modules"
  cp "$ROOT_DIR/bin/basm" "$cli/bin/basm"
  printf 'source %q\n' "$ROOT_DIR/modules/core.sh" > "$cli/modules/core.sh"
  cat >> "$cli/modules/core.sh" <<'EOF'
require_root() { :; }
load_deployment_env() { :; }
acquire_operation_lock() { :; }
install_operation_trap() { :; }
adopt_backup_mount() { printf 'adoption invoked\n'; }
EOF
  [[ "$(bash "$cli/bin/basm" backup-adopt-mount)" == 'adoption invoked' ]]
  expect_failure bash "$cli/bin/basm" backup-adopt-mount extra
)
printf 'Shared backup adoption, full-data verification and missing-mount safeguards passed.\n'
