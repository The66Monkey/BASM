#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing WireGuard module"
  ensure_port_defaults
  ensure_dir "$BASM_ROOT/modules/wireguard"
  cat > "$BASM_ROOT/modules/wireguard/config.conf" <<EOF
[Interface]
Address = 10.0.10.1/24
SaveConfig = true
ListenPort = $WIREGUARD_PORT
PrivateKey = CHANGE_ME

[Peer]
PublicKey = CHANGE_ME
PresharedKey = CHANGE_ME
AllowedIPs = 10.0.10.2/32
EOF
  log "WireGuard module configuration generated"
}
