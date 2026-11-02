#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/modules/core.sh"
[[ $# == 2 ]] || fail "Usage: sudo bash recover.sh EXTERNAL_BASM_ENV SNAPSHOT_ID"
require_root
check_debian
ensure_packages python3 jq
BASM_ENV_FILE="$(realpath -e "$1")"
load_deployment_env --recovery
validate_backup_path "$BASM_ROOT" || fail "Unsafe deployment path."
[[ "$BASM_ROOT" != / && ! -e "$BASM_ROOT" ]] ||
  fail "Recovery requires a fresh host with no existing deployment directory. Do not remove live data to retry."
ensure_packages $BASM_REQUIRED_PACKAGES
ensure_docker
identifier="$(printf '%s' "$BASM_ROOT" | sha256sum | cut -c1-16)"
exec 9> "/run/lock/basm-recovery-$identifier.lock"
flock -n 9 || fail "Another recovery is already running."
containers="$(docker ps -aq --filter "name=^${BASM_CONTAINER_PREFIX}-")"
[[ -z "$containers" ]] || fail "Existing BASM containers found; use an empty replacement host."
parent="$(dirname "$BASM_ROOT")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/basm-recovery.XXXXXX")"
# restore_deployment deliberately requires a target that does not exist.
rmdir "$stage"
restore_deployment "$2" "$stage"
restored="$stage$BASM_ROOT"
[[ -f "$restored/maintenance/bin/basm" ]] || fail "Backup does not contain BASM operator tools."
mv "$restored" "$BASM_ROOT"
acquire_operation_lock
BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
load_deployment_env
# A replacement host may use a different backup filesystem.
rm -f "$BASM_ROOT/config/backup-device"
initialize_repository
ROOT_DIR="$BASM_ROOT/maintenance"
source "$ROOT_DIR/modules/core.sh"
install_operation_trap "Recovery"
install_runtime
basm_stack pull --quiet
basm_stack up -d --wait --wait-timeout 900 --remove-orphans
while IFS= read -r file; do
  [[ "${file%/*}" != "$BASM_ROOT/modules/fluxer" ]] || continue
  module_compose "$file" pull --quiet
  module_compose "$file" up -d --wait --wait-timeout 900 --remove-orphans
done < <(module_compose_files "$BASM_ROOT")
if module_selected fluxer; then
  [[ -f "$BASM_ROOT/data/fluxer-recovery.tar.zst" && -x "$BASM_ROOT/config/rexctl" ]] ||
    fail "Fluxer recovery archive or saved manager is missing."
  install -m 755 "$BASM_ROOT/config/rexctl" /usr/local/bin/rexctl
  source "$ROOT_DIR/modules/fluxer.sh"
  fluxer_rexctl restore "$BASM_ROOT/data/fluxer-recovery.tar.zst" --confirm "$FLUXER_DOMAIN" --yes
  fluxer_rexctl backup location "$BACKUP_LOCATION/fluxer"
fi
# Recovering a pre-update snapshot must not retain an interruption marker.
rm -f "$BASM_ROOT/config/update-in-progress"
backup_deployment
check_deployment
install_auto_updates
install_ddns_updater
log "Recovery completed. Verify accounts, files, mail and optional services before cutover."
log "Restore staging remains at $stage; remove it after acceptance."
