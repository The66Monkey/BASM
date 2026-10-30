#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing KeePassXC credential manager"
  ensure_packages keepassxc python3-pykeepass
  sync_keepass >/dev/null || fail "Could not create or open the KeePass database."
  log "KeePass database ready at $BASM_ROOT/config/credentials.kdbx"
}