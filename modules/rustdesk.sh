#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/rustdesk}" server_host
  log "Installing RustDesk Server OSS module"
  ensure_port_defaults
  server_host="${PRIMARY_DOMAIN:-localhost}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then server_host="${BIND_ADDRESS:-127.0.0.1}"; fi
  ensure_dir "$module_dir/data" || return
  chmod 700 "$module_dir/data" || return
  cat > "$module_dir/docker-compose.yml" <<EOF || return
name: ${BASM_CONTAINER_PREFIX:-basm}-rustdesk
services:
  hbbs:
    image: rustdesk/rustdesk-server:1.1.16
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-rustdesk-hbbs
    command: ["hbbs", "-r", "$server_host:$RUSTDESK_RELAY_PORT", "-k", "_"]
    restart: unless-stopped
    depends_on:
      - hbbr
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:$RUSTDESK_NAT_PORT:21115"
      - "${BIND_ADDRESS:-0.0.0.0}:$RUSTDESK_ID_PORT:21116"
      - "${BIND_ADDRESS:-0.0.0.0}:$RUSTDESK_ID_PORT:21116/udp"
    volumes:
      - ./data:/root
  hbbr:
    image: rustdesk/rustdesk-server:1.1.16
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-rustdesk-hbbr
    command: ["hbbr", "-k", "_"]
    restart: unless-stopped
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:$RUSTDESK_RELAY_PORT:21117"
    volumes:
      - ./data:/root
EOF
  log "RustDesk module configuration generated; public key: $module_dir/data/id_ed25519.pub (created at first start)"
}

module_start() {
  start_module_stack rustdesk
}