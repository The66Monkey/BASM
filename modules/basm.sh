#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing BASM core components"

  ensure_dir "$BASM_ROOT/config"
  ensure_dir "$BASM_ROOT/data/erpnext"
  ensure_dir "$BASM_ROOT/data/postal"
  ensure_dir "$BASM_ROOT/data/nextcloud"
  ensure_dir "$BASM_ROOT/data/restic"
  ensure_dir "$BASM_ROOT/data/traefik"

  cp "$ROOT_DIR/config/basm.env" "$BASM_ROOT/config/basm.env"
  envsubst < "$ROOT_DIR/templates/docker-compose.yml" > "$BASM_ROOT/docker-compose.yml"
  envsubst < "$ROOT_DIR/templates/traefik.yml" > "$BASM_ROOT/config/traefik.yml"

  if command -v docker >/dev/null 2>&1; then
    log "Starting BASM Docker stack"
    docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" up -d --remove-orphans || warn "Docker stack did not start cleanly. Review the compose file and logs manually."
  else
    warn "DockerCLI was not found; BASM stack was generated but not started."
  fi

  log "BASM core installation complete"
}
