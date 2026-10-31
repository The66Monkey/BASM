#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  warn "Vaultwarden is deprecated and is no longer installed. Use KeePassXC for credential management."
}
