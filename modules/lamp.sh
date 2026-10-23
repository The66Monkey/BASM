#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing LAMP module"
  ensure_port_defaults
  ensure_dir "$BASM_ROOT/modules/lamp/www"
  if [[ -z "$(ls -A "$BASM_ROOT/modules/lamp/www")" ]]; then
    cat > "$BASM_ROOT/modules/lamp/www/index.html" <<HTML
<!doctype html>
<title>${COMPANY_NAME:-BASM}</title>
<p>The BASM LAMP module is running. Replace the files in $BASM_ROOT/modules/lamp/www with your site.</p>
HTML
  fi
  cat > "$BASM_ROOT/modules/lamp/docker-compose.yml" <<EOT
name: ${BASM_CONTAINER_PREFIX:-basm}-lamp
services:
  lamp:
    image: php:8.3-apache
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-lamp
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:$LAMP_PORT:80"
    environment:
      APP_ENV: ${DEPLOYMENT_MODE:-production}
    volumes:
      - ./www:/var/www/html
    restart: unless-stopped
EOT
  log "LAMP module configuration generated"
}

module_start() {
  start_module_stack lamp
}
