#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/uptime-kuma}"
  log "Installing Uptime Kuma module"
  ensure_port_defaults
  ensure_dir "$module_dir" || return
  cat > "$module_dir/docker-compose.yml" <<EOF || return
name: ${BASM_CONTAINER_PREFIX:-basm}-uptime-kuma
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-uptime-kuma
    restart: unless-stopped
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:$UPTIME_KUMA_PORT:3001"
    volumes:
      - ./data:/app/data
EOF
  log "Uptime Kuma module configuration generated"
}

module_start() {
  start_module_stack uptime-kuma
}
