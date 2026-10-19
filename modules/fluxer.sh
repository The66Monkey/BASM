#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing Fluxer module"
  ensure_dir "$BASM_ROOT/modules/fluxer"
  cat > "$BASM_ROOT/modules/fluxer/README.md" <<EOF
Fluxer is a lightweight automation service for BASM.

This generated module keeps the BASM install modular and easy to replace with a different task runner later.
EOF
  log "Fluxer module configuration generated"
}
