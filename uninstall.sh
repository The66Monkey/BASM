#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
OUTPUT_DIR="$ROOT_DIR/output"
case "${1:-}" in
  --help|-h)
    printf 'Usage: ./uninstall.sh\n'
    exit 0
    ;;
esac
[[ $# -eq 0 ]] || { printf 'Usage: ./uninstall.sh\n' >&2; exit 1; }
BASM_ROOT="${BASM_ROOT:-/opt/basm}"
PRODUCTION_BASM_ROOT="$BASM_ROOT"
LOCAL_BASM_ROOT="$BASM_ROOT"
if [[ "$LOCAL_BASM_ROOT" == /opt/basm ]]; then LOCAL_BASM_ROOT=/opt/basm-local; fi

source "$ROOT_DIR/modules/core.sh"

require_root
select_deployment

if [[ "$LOCAL_MODE" == true ]]; then
  [[ -f "$BASM_ROOT/config/basm.env" ]] || fail "No local BASM configuration was found at $BASM_ROOT"
  source "$BASM_ROOT/config/basm.env"
  [[ "${DEPLOYMENT_MODE:-}" == local ]] || fail "The selected configuration is not a local test setup."
fi

read -rp "This will stop and remove BASM services and data under $BASM_ROOT. Continue? [y/N]: " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  log "Uninstall cancelled."
  exit 0
fi

purge_deployment "$BASM_ROOT"

log "BASM has been removed."
