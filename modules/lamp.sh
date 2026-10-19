#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing LAMP module"
  ensure_dir "$BASM_ROOT/modules/lamp"
  cat > "$BASM_ROOT/modules/lamp/docker-compose.yml" <<EOF
services:
  lamp:
    image: php:8.3-apache
    container_name: basm-lamp
    ports:
      - "8080:80"
    environment:
      APP_ENV: production
    restart: unless-stopped
EOF
  log "LAMP module configuration generated"
}
