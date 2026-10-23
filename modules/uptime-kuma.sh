#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing Uptime Kuma module"
  ensure_port_defaults
  ensure_dir "$BASM_ROOT/modules/uptime-kuma"
  cat > "$BASM_ROOT/modules/uptime-kuma/docker-compose.yml" <<EOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-uptime-kuma
    restart: unless-stopped
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:$UPTIME_KUMA_PORT:3001"
    volumes:
      - ./data:/app/data
EOF
  log "Uptime Kuma module configuration generated"
}
