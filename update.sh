#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASM_ROOT="${BASM_ROOT:-/opt/basm}"

source "$ROOT_DIR/modules/core.sh"

require_root

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
