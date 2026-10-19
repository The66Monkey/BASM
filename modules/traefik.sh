#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing Traefik reverse proxy configuration"
  ensure_dir "$BASM_ROOT/modules/traefik"
  cat > "$BASM_ROOT/modules/traefik/dynamic.yml" <<EOF
http:
  routers:
    erp:
      rule: "Host(`$ERP_URL`)"
      service: erp-service
    mail:
      rule: "Host(`$MAIL_URL`)"
      service: mail-service
    cloud:
      rule: "Host(`$CLOUD_URL`)"
      service: cloud-service
  services:
    erp-service:
      loadBalancer:
        servers:
          - url: "http://erpnext:8080"
    mail-service:
      loadBalancer:
        servers:
          - url: "http://postal:5000"
    cloud-service:
      loadBalancer:
        servers:
          - url: "http://nextcloud:80"
EOF
  log "Traefik module configuration generated"
}
