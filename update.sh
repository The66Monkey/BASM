#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
case "${1:-}" in
  --help|-h)
    printf 'Usage: ./update.sh\n'
    exit 0
    ;;
esac
[[ $# -eq 0 ]] || { printf 'Usage: ./update.sh\n' >&2; exit 1; }
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
  validate_local_bind_address "$BIND_ADDRESS" || fail "Unsafe local bind address."
fi

if [[ ! -f "$BASM_ROOT/docker-compose.yml" ]]; then
  fail "No BASM stack was found at $BASM_ROOT"
fi

log "Pulling latest Docker images"
docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" pull || fail "Failed to pull new images"

log "Recreating containers with preserved volumes"
docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" up -d --remove-orphans || fail "Failed to recreate containers"

log "Validating BASM stack health"
docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" ps || fail "Stack health validation failed"

log "Update completed successfully"
