#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
OUTPUT_DIR="$ROOT_DIR/output"
BASM_ROOT="${BASM_ROOT:-/opt/basm}"

source "$ROOT_DIR/modules/core.sh"

require_root

if [[ -f "$CONFIG_DIR/basm.env" ]]; then
  source "$CONFIG_DIR/basm.env"
fi

read -rp "This will stop and remove BASM services and data under $BASM_ROOT. Continue? [y/N]: " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  log "Uninstall cancelled."
  exit 0
fi

if [[ -f "$BASM_ROOT/docker-compose.yml" ]]; then
  log "Stopping BASM Docker stack"
  docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" down -v --remove-orphans || true
fi

if [[ -d "$BASM_ROOT" ]]; then
  rm -rf "$BASM_ROOT"
fi

log "BASM has been removed."
