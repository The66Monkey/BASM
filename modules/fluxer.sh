#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

fluxer_rexctl() {
  command -v rexctl >/dev/null 2>&1 || fail "Fluxer rexctl is missing. Re-run the Fluxer module installer."
  rexctl "$@" --dir "${BASM_ROOT}/modules/fluxer"
}

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/fluxer}"
  local installer gateway
  local -a install_args=()

  log "Installing Fluxer module"
  [[ "${DEPLOYMENT_MODE:-production}" != local ]] || \
    fail "Fluxer requires production HTTPS and public network access; it cannot be installed in BASM local mode."
  validate_domain "${FLUXER_DOMAIN:-}" || fail "A valid Fluxer domain must be configured."
  validate_port "${FLUXER_PROXY_PORT:-}" || fail "A valid Fluxer proxy port must be configured."
  ensure_dir "$module_dir"
  chmod 700 "$module_dir"

  if [[ ! -d "$module_dir/.rexctl" ]]; then
    gateway="$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' bridge)" || \
      fail "Could not determine the Docker bridge gateway for the Fluxer proxy."
    [[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || \
      fail "Docker returned an invalid bridge gateway: $gateway"

    installer="$module_dir/fluxer-install.sh"
    curl -fsSL https://fluxer.dev/install.sh -o "$installer" || \
      fail "Could not download the official Fluxer installer."
    chmod 700 "$installer"

    install_args=(
      install
      --dir "$module_dir"
      --project "${BASM_CONTAINER_PREFIX:-basm}-fluxer"
      --domain "$FLUXER_DOMAIN"
      --confirm "$FLUXER_DOMAIN"
      --name "${COMPANY_NAME:-BASM} Chat"
      --registration invite
      --sign-in username
      --skip-email
      --setup terminal
      --install-docker=false
      --open-firewall=false
      --behind-proxy
      --bind "$gateway:$FLUXER_PROXY_PORT"
    )
    install_args+=(
      --voice-tcp-port "${FLUXER_VOICE_TCP_PORT:-17881}"
      --voice-udp-port "${FLUXER_VOICE_UDP_PORT:-17882}"
    )

    if ! bash "$installer" "${install_args[@]}"; then
      rm -f "$installer"
      fail "The official Fluxer installer failed. See its output above."
    fi
    rm -f "$installer"
  fi

  ensure_dir "$BACKUP_LOCATION/fluxer"
  chmod 700 "$BACKUP_LOCATION/fluxer"
  fluxer_rexctl backup location "$BACKUP_LOCATION/fluxer" || \
    fail "Could not configure the Fluxer backup location."
  fluxer_rexctl backup keep 7 || fail "Could not configure Fluxer backup retention."
  fluxer_rexctl backup || fail "Could not create the initial Fluxer backup."
  basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" \
    exec -T restic-backup restic backup /source/fluxer-backups || \
    fail "Could not add the initial Fluxer backup to Restic."
  log "Fluxer module installed at https://$FLUXER_DOMAIN"
}

module_start() {
  fluxer_rexctl start || fail "Fluxer did not start cleanly."
}

module_stop() {
  fluxer_rexctl stop
}

module_backup() {
  fluxer_rexctl backup || return
  fluxer_rexctl backup keep 7
}

module_update() {
  fluxer_rexctl upgrade
}

module_uninstall() {
  fluxer_rexctl uninstall --confirm "$FLUXER_DOMAIN"
}
