#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing Vaultwarden module"
  ensure_dir "$BASM_ROOT/modules/vaultwarden"
  cat > "$BASM_ROOT/modules/vaultwarden/README.md" <<EOF
Vaultwarden provides a lightweight, self-hosted Bitwarden-compatible service for BASM users.
EOF
  log "Vaultwarden module configuration generated"
}
