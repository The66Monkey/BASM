#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

wireguard_private_key() {
  openssl genpkey -algorithm X25519 -outform DER | tail -c 32 | base64
}

wireguard_public_key() {
  { printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'; base64 -d <<< "$1"; } |
    openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
}

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/wireguard}"
  local server_private server_public peer_private peer_public preshared endpoint
  log "Installing WireGuard module"
  ensure_port_defaults
  ensure_dir "$module_dir" || return
  endpoint="${PRIMARY_DOMAIN:-localhost}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then endpoint="${BIND_ADDRESS:-127.0.0.1}"; fi
  if [[ -f "$module_dir/config.conf" ]] && ! grep -q CHANGE_ME "$module_dir/config.conf"; then
    sed -i "s/^ListenPort = .*/ListenPort = $WIREGUARD_PORT/" "$module_dir/config.conf" || return
    if [[ -f "$module_dir/peer1.conf" ]]; then
      sed -i "s/^Endpoint = .*/Endpoint = $endpoint:$WIREGUARD_PORT/" "$module_dir/peer1.conf" || return
    fi
    log "WireGuard configuration already exists; keys were kept"
    return 0
  fi

  server_private="$(wireguard_private_key)" || return
  server_public="$(wireguard_public_key "$server_private")" || return
  peer_private="$(wireguard_private_key)" || return
  peer_public="$(wireguard_public_key "$peer_private")" || return
  preshared="$(openssl rand -base64 32)" || return
  (
    umask 077
    cat > "$module_dir/config.conf" <<EOT || return
[Interface]
Address = 10.0.10.1/24
ListenPort = $WIREGUARD_PORT
PrivateKey = $server_private

[Peer]
PublicKey = $peer_public
PresharedKey = $preshared
AllowedIPs = 10.0.10.2/32
EOT
    cat > "$module_dir/peer1.conf" <<EOT || return
[Interface]
Address = 10.0.10.2/32
PrivateKey = $peer_private

[Peer]
PublicKey = $server_public
PresharedKey = $preshared
Endpoint = $endpoint:$WIREGUARD_PORT
AllowedIPs = 10.0.10.0/24
PersistentKeepalive = 25
EOT
  ) || return
  log "WireGuard server and peer configuration generated with new keys"
}
