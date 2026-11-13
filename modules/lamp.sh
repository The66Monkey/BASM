#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/lamp}" hotdog_volumes=""
  local hotdog_network="" hotdog_network_definition=""
  log "Installing LAMP module"
  ensure_port_defaults
  ensure_dir "$module_dir/www" || return
  chmod 755 "$module_dir/www" || return
  if [[ -z "$(ls -A "$module_dir/www")" ]]; then
    cat > "$module_dir/www/index.html" <<HTML || return
<!doctype html>
<title>${COMPANY_NAME:-BASM}</title>
<p>The BASM LAMP module is running. Replace the files in $BASM_ROOT/modules/lamp/www with your site.</p>
HTML
    chmod 644 "$module_dir/www/index.html" || return
  fi
  if module_selected hotdog; then
    [[ ! -L "$module_dir/hotdog" ]] || fail "HotDog document root cannot be a symbolic link."
    [[ ! -L "$module_dir/hotdog-vhost.conf" ]] || fail "HotDog Apache configuration cannot be a symbolic link."
    ensure_dir "$module_dir/hotdog" || return
    chmod 755 "$module_dir/hotdog" || return
    cat > "$module_dir/hotdog-vhost.conf" <<APACHE || return
<VirtualHost *:80>
  ServerName hotdog.${PRIMARY_DOMAIN}
  DocumentRoot /var/www/hotdog/current
  <Directory /var/www/hotdog/current>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
  </Directory>
  DirectoryIndex index.html
  ErrorDocument 404 /404.html
  AddType text/calendar .ics
  <FilesMatch "^\\.hotdog-cms-">
    Require all denied
  </FilesMatch>
  ErrorLog /proc/self/fd/2
  CustomLog /proc/self/fd/1 combined
</VirtualHost>
APACHE
    chmod 644 "$module_dir/hotdog-vhost.conf" || return
    hotdog_volumes=$'      - ./hotdog:/var/www/hotdog:ro\n      - ./hotdog-vhost.conf:/etc/apache2/sites-enabled/001-hotdog.conf:ro\n'
    hotdog_network=$'    networks:\n      basm-net:\n        aliases:\n          - basm-hotdog-lamp\n'
    hotdog_network_definition=$'\nnetworks:\n  basm-net:\n    external: true\n    name: '"${BASM_CONTAINER_PREFIX:-basm}-net"
  fi
  cat > "$module_dir/docker-compose.yml" <<EOT || return
name: ${BASM_CONTAINER_PREFIX:-basm}-lamp
services:
  lamp:
    image: php:8.3-apache
    container_name: ${BASM_CONTAINER_PREFIX:-basm}-lamp
    ports:
      - "$MANAGEMENT_BIND_ADDRESS:$LAMP_PORT:80"
    environment:
      APP_ENV: ${DEPLOYMENT_MODE:-production}
    volumes:
      - ./www:/var/www/html
${hotdog_volumes}    restart: unless-stopped
${hotdog_network}
EOT
  if [[ -n "$hotdog_network_definition" ]]; then
    printf '%s\n' "$hotdog_network_definition" >> "$module_dir/docker-compose.yml" || return
  fi
  log "LAMP module configuration generated"
}

module_start() {
  start_module_stack lamp
}
