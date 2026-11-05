#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing BASM core components"

  ensure_dir "$BASM_ROOT/config"
  prepare_stalwart_storage || fail "Cannot prepare Stalwart configuration storage."
  ensure_dir "$BASM_ROOT/data/erpnext"
  ensure_dir "$BASM_ROOT/data/nextcloud"
  ensure_dir "$BASM_ROOT/data/restic"
  ensure_dir "$BASM_ROOT/data/traefik"
  ensure_dir "$BASM_ROOT/data/erpnext-logs"
  ensure_dir "$BASM_ROOT/data/db-backups"
  chmod 700 "$BASM_ROOT/data/db-backups"

  chown -R 1000:1000 "$BASM_ROOT/data/erpnext" "$BASM_ROOT/data/erpnext-logs"
  if [[ "${BASM_ENV_FILE:-}" != "$BASM_ROOT/config/basm.env" ]]; then
    cp "${BASM_ENV_FILE:-$ROOT_DIR/config/basm.env}" "$BASM_ROOT/config/basm.env"
    chmod 600 "$BASM_ROOT/config/basm.env"
  fi
  render_stack || fail "Cannot render the BASM stack."

  if command -v docker >/dev/null 2>&1; then
    log "Starting BASM Docker stack"
    basm_stack up -d --remove-orphans --quiet-pull || fail "Docker stack did not start cleanly. Review the Compose output and logs."
    basm_stack wait erpnext-create-site || fail "The ERPNext site initialization job failed. Review the Compose logs."
    basm_stack up -d --wait --wait-timeout 900 --remove-orphans --quiet-pull || fail "Docker stack did not reach its final running state."
  else
    fail "Docker CLI was not found; the BASM stack cannot be started."
  fi

  log "BASM core installation complete"
}
