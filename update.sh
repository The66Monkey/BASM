#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/modules/core.sh"
SCHEDULED=false
EXPLICIT_ROOT=false
RELEASE="$ROOT_DIR"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      printf 'Usage: update.sh [--root DIRECTORY | --scheduled DIRECTORY] [--release TRUSTED_CHECKOUT]\n'
      exit 0 ;;
    --root|--scheduled)
      [[ $# -ge 2 && "$EXPLICIT_ROOT" == false ]] || fail "Select one deployment directory."
      [[ "$1" != --scheduled ]] || SCHEDULED=true
      BASM_ROOT="$2"; EXPLICIT_ROOT=true; shift 2 ;;
    --release)
      [[ $# -ge 2 ]] || fail "--release requires a checkout path."
      RELEASE="$(realpath -e "$2")"; shift 2 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
require_root
if [[ "$EXPLICIT_ROOT" == false ]]; then
  PRODUCTION_BASM_ROOT="$BASM_ROOT"
  LOCAL_BASM_ROOT="$BASM_ROOT"
  [[ "$LOCAL_BASM_ROOT" != /opt/basm ]] || LOCAL_BASM_ROOT=/opt/basm-local
  select_deployment
else
  BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
fi
load_deployment_env
[[ -f "$BASM_ROOT/docker-compose.yml" ]] || fail "No BASM stack found."
install_operation_trap "Application update"
if [[ "$SCHEDULED" == true ]]; then
  [[ ! -e "$BASM_ROOT/config/disable-auto-updates" ]] || exit 0
  hour="$(date +%H)"
  scheduled_update_window "$hour" || fail "Scheduled updates only run between 00:00 and 06:00 server time."
  acquire_operation_lock update 7200
  scheduled_update_window "$(date +%H)" || fail "Maintenance window ended while waiting for the BASM lock."
else
  acquire_operation_lock
fi
update_deployment "$RELEASE"
