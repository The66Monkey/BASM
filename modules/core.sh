#!/usr/bin/env bash

BASM_ROOT="${BASM_ROOT:-/opt/basm}"
LOG_FILE="${LOG_FILE:-${BASM_ROOT}/logs/install.log}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  log "ERROR: $*"
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "This installer must be run as root. Use sudo ./install.sh"
  fi
}

check_debian() {
  if [[ ! -f /etc/os-release ]]; then
    fail "This installer only supports Debian-based systems."
  fi

  . /etc/os-release
  if [[ "$ID" != "debian" ]]; then
    fail "This installer supports Debian only. Detected: $ID"
  fi

  log "Detected Debian ${VERSION_ID:-unknown}"
}

ensure_dir() {
  mkdir -p "$1"
}

prepare_stalwart_storage() {
  local directory
  for directory in "$BASM_ROOT/config/stalwart" "$BASM_ROOT/data/stalwart"; do
    install -d -m 750 "$directory" || return
    chmod 750 "$directory" || return
    chown 2000:2000 "$directory" || return
  done
}

install_login_banner() {
  local profile_dir="${BASM_PROFILE_DIR:-/etc/profile.d}"
  install -d -m 755 "$profile_dir" || fail "Could not create the BASM login profile directory."
  install -m 644 "$ROOT_DIR/templates/profile.d/basm.sh" "$profile_dir/basm.sh" ||
    fail "Could not install the BASM login banner."
}

BASM_FULL_MODULES="basm lamp wireguard uptime-kuma fluxer keepass rustdesk"
BASM_PREPARED_MODULES="lamp wireguard uptime-kuma rustdesk"
BASM_REQUIRED_PACKAGES="ca-certificates curl gnupg lsb-release gettext-base tzdata net-tools iproute2 openssl cron util-linux python3 python3-yaml jq restic"

package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Installs only missing packages and never upgrades installed ones, so reruns,
# upgrades, and promotions do not download packages unnecessarily.
ensure_packages() {
  local package
  local -a missing=()
  for package in "$@"; do
    package_installed "$package" || missing+=("$package")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log "Required packages are already installed"
    return 0
  fi
  log "Installing missing packages: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || fail "apt-get update failed"
  apt-get install -y --no-upgrade "${missing[@]}" || fail "Failed to install: ${missing[*]}"
}

module_selected() {
  [[ " ${BASM_MODULES:-basm} " == *" $1 "* ]]
}

# Compose gives exported shell variables precedence over --env-file. Run it with
# only the variables it needs so a stale or different deployment's values
# (for example during promotion rollback) can never leak into a stack.
basm_compose() {
  (
    local variable
    while IFS= read -r variable; do
      case "$variable" in
        PATH|HOME|USER|LANG|LC_*|TERM|TMPDIR|DOCKER_*|COMPOSE_*|BUILDKIT_*) ;;
        *) export -n "$variable" 2>/dev/null || true ;;
      esac
    done < <(compgen -e)
    docker compose "$@"
  )
}

module_compose_files() {
  local root="${1:-$BASM_ROOT}" module file
  local -a selected_modules=()
  read -r -a selected_modules <<< "${BASM_MODULES:-basm}"
  for module in "${selected_modules[@]}"; do
    [[ "$module" != basm ]] || continue
    file="$root/modules/$module/docker-compose.yml"
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
  return 0
}

module_compose() {
  local compose_file="$1" module_dir="${1%/docker-compose.yml}"
  shift
  local -a image_lock=()
  [[ ! -f "$module_dir/.basm-images.json" ]] || image_lock=(-f "$module_dir/.basm-images.json")
  if [[ -f "$module_dir/.env" && -f "$module_dir/docker-compose.proxy.yml" && -f "$module_dir/docker-compose.basm.yml" ]]; then
    basm_compose --env-file "$module_dir/.env" \
      -f "$compose_file" \
      -f "$module_dir/docker-compose.proxy.yml" \
      -f "$module_dir/docker-compose.basm.yml" "${image_lock[@]}" "$@"
  else
    basm_compose -f "$compose_file" "${image_lock[@]}" "$@"
  fi
}

start_module_stack() {
  local compose_file="$BASM_ROOT/modules/$1/docker-compose.yml"
  command -v docker >/dev/null 2>&1 || fail "Docker CLI was not found; module '$1' cannot be started."
  log "Starting $1 module"
  module_compose "$compose_file" up -d --remove-orphans --quiet-pull || fail "Module '$1' did not start cleanly."
}

port_in_use() {
  local port="$1"
  local options=-lnt
  if [[ "${2:-tcp}" == udp ]]; then options=-lnu; fi
  if command -v ss >/dev/null 2>&1; then
    ss "$options" 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" && return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat "$options" 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" && return 0
  fi

  return 1
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Let's Encrypt rejects reserved example/test domains as account contacts.
validate_production_email() {
  local domain="${1##*@}"
  validate_email "$1" || return 1
  domain="${domain,,}"
  case "$domain" in
    example.com|example.net|example.org|*.example|*.test|*.invalid|*.localhost|localhost) return 1 ;;
  esac
}

validate_admin_username() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]
}

validate_company_name() {
  local pattern="^[A-Za-z0-9][A-Za-z0-9 &,.'()_-]{0,79}$"
  [[ "$1" =~ $pattern ]]
}

validate_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f "/usr/share/zoneinfo/$1" ]]
}

validate_backup_path() {
  [[ "$1" =~ ^/[A-Za-z0-9_./-]+$ && "$1" != *"/../"* && "$1" != */.. ]]
}

generate_secret() {
  openssl rand -hex 32
}

generate_password() {
  local password
  while true; do
    password="$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9')" || return
    password="${password:0:32}"
    [[ ${#password} -eq 32 && "$password" =~ [A-Z] && "$password" =~ [a-z] && "$password" =~ [0-9] ]] || continue
    printf '%s\n' "$password"
    return 0
  done
}

sync_keepass() {
  printf '%s\0' "${DEPLOYMENT_MODE:-production}" "$HTTP_PORT" "$HTTPS_PORT" "$ERP_URL" "$MAIL_URL" "$CLOUD_URL" \
    "$ERP_ADMIN_PASSWORD" "$NEXTCLOUD_ADMIN_USER" "$NEXTCLOUD_ADMIN_PASSWORD" "$ADMIN_EMAIL" \
    "$DB_ROOT_PASSWORD" "$NEXTCLOUD_DB_PASSWORD" "$RESTIC_PASSWORD" "$BACKUP_LOCATION" "${DESEC_TOKEN:-}" "${BASM_MODULES:-basm}" \
    "${MANAGEMENT_BIND_ADDRESS:-$BIND_ADDRESS}" "$UPTIME_KUMA_PORT" | /usr/bin/python3 "$ROOT_DIR/templates/keepass-sync.py" "$BASM_ROOT"
}

validate_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

validate_desec_token() {
  [[ "$1" =~ ^[A-Za-z0-9._~+/=-]{16,128}$ ]]
}

ensure_port_defaults() {
  MANAGEMENT_BIND_ADDRESS="${MANAGEMENT_BIND_ADDRESS:-${BIND_ADDRESS:-127.0.0.1}}"
  [[ "$MANAGEMENT_BIND_ADDRESS" != 0.0.0.0 ]] || MANAGEMENT_BIND_ADDRESS=127.0.0.1
  SMTP_BIND_ADDRESS="${SMTP_BIND_ADDRESS:-${BIND_ADDRESS:-127.0.0.1}}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    WEB_PROTOCOL="${WEB_PROTOCOL:-http}"
  else
    WEB_PROTOCOL="${WEB_PROTOCOL:-https}"
  fi
  MAILBOX_HOSTNAME="${MAILBOX_HOSTNAME:-mx.${PRIMARY_DOMAIN:-example.com}}"
  MAILBOX_BIND_ADDRESS="${MAILBOX_BIND_ADDRESS:-${BIND_ADDRESS:-127.0.0.1}}"
  MAILBOX_SETUP_BIND_ADDRESS=127.0.0.1
  validate_local_bind_address "$MANAGEMENT_BIND_ADDRESS" || fail "Management listeners require loopback or a private LAN IPv4."
  local default_http=80 default_https=443 default_lamp=8080 default_kuma=3001 default_wireguard=51820
  local default_fluxer_tcp=7881 default_fluxer_udp=7882
  local default_smtp=25
  local default_mailbox_submission=465 default_mailbox_imaps=993 default_mailbox_setup=18082
  local default_fluxer_proxy=8088 default_fluxer_voice_tcp=17881 default_fluxer_voice_udp=17882
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    default_http=18080 default_https=18443 default_lamp=18081 default_kuma=18301 default_wireguard=18520
    default_fluxer_tcp=17881 default_fluxer_udp=17882
    default_smtp=2525
    default_mailbox_submission=12465 default_mailbox_imaps=12993
    default_fluxer_proxy=18088 default_fluxer_voice_tcp=17881 default_fluxer_voice_udp=17882
  fi
  HTTP_PORT="${HTTP_PORT:-$default_http}"
  HTTPS_PORT="${HTTPS_PORT:-$default_https}"
  LAMP_PORT="${LAMP_PORT:-$default_lamp}"
  UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-$default_kuma}"
  WIREGUARD_PORT="${WIREGUARD_PORT:-$default_wireguard}"
  local default_rustdesk_nat=21115 default_rustdesk_id=21116 default_rustdesk_relay=21117
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    default_rustdesk_nat=22115 default_rustdesk_id=22116 default_rustdesk_relay=22117
  fi
  RUSTDESK_NAT_PORT="${RUSTDESK_NAT_PORT:-$default_rustdesk_nat}"
  RUSTDESK_ID_PORT="${RUSTDESK_ID_PORT:-$default_rustdesk_id}"
  RUSTDESK_RELAY_PORT="${RUSTDESK_RELAY_PORT:-$default_rustdesk_relay}"
  FLUXER_PROXY_PORT="${FLUXER_PROXY_PORT:-$default_fluxer_proxy}"
  FLUXER_VOICE_TCP_PORT="${FLUXER_VOICE_TCP_PORT:-$default_fluxer_voice_tcp}"
  FLUXER_VOICE_UDP_PORT="${FLUXER_VOICE_UDP_PORT:-$default_fluxer_voice_udp}"
  FLUXER_DOMAIN="${FLUXER_DOMAIN:-chat.${PRIMARY_DOMAIN:-example.com}}"
  SMTP_PORT="${SMTP_PORT:-$default_smtp}"
  MAILBOX_SUBMISSION_PORT="${MAILBOX_SUBMISSION_PORT:-$default_mailbox_submission}"
  MAILBOX_IMAPS_PORT="${MAILBOX_IMAPS_PORT:-$default_mailbox_imaps}"
  MAILBOX_SETUP_PORT="${MAILBOX_SETUP_PORT:-$default_mailbox_setup}"
  SSH_PORT="${SSH_PORT:-22}"
  export HTTP_PORT HTTPS_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT FLUXER_PROXY_PORT \
    FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT FLUXER_DOMAIN SSH_PORT SMTP_BIND_ADDRESS SMTP_PORT WEB_PROTOCOL \
    RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT MAILBOX_HOSTNAME MAILBOX_BIND_ADDRESS \
    MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT
}

set_port_defaults() {
  HTTP_PORT=80
  HTTPS_PORT=443
  LAMP_PORT=8080
  UPTIME_KUMA_PORT=3001
  WIREGUARD_PORT=51820
  RUSTDESK_NAT_PORT=21115
  RUSTDESK_ID_PORT=21116
  RUSTDESK_RELAY_PORT=21117
  FLUXER_PROXY_PORT=8088
  FLUXER_VOICE_TCP_PORT=17881
  FLUXER_VOICE_UDP_PORT=17882
  SMTP_PORT=25
  MAILBOX_SUBMISSION_PORT=465
  MAILBOX_IMAPS_PORT=993
  MAILBOX_SETUP_PORT=18082
  if [[ "$1" == local ]]; then
    HTTP_PORT=18080
    HTTPS_PORT=18443
    LAMP_PORT=18081
    UPTIME_KUMA_PORT=18301
    WIREGUARD_PORT=18520
    RUSTDESK_NAT_PORT=22115
    RUSTDESK_ID_PORT=22116
    RUSTDESK_RELAY_PORT=22117
    FLUXER_PROXY_PORT=18088
    FLUXER_VOICE_TCP_PORT=17881
    FLUXER_VOICE_UDP_PORT=17882
    SMTP_PORT=2525
    MAILBOX_SUBMISSION_PORT=12465
    MAILBOX_IMAPS_PORT=12993
  fi
}

validate_port_plan() {
  local -A assigned=(["${SSH_PORT:-22}"]="host SSH") assigned_udp=()
  local variable module_name port
  local -a tcp_ports=(HTTP_PORT HTTPS_PORT SMTP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT MAILBOX_SETUP_PORT)
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) tcp_ports+=(LAMP_PORT) ;;
      uptime-kuma) tcp_ports+=(UPTIME_KUMA_PORT) ;;
      rustdesk) tcp_ports+=(RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT) ;;
      fluxer) tcp_ports+=(FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT) ;;
    esac
  done
  for variable in "${tcp_ports[@]}"; do
    port="${!variable}"
    validate_port "$port" || { warn "Invalid port for $variable: $port"; return 1; }
    if [[ "${assigned[$port]:-}" == "$variable" ]]; then continue; fi
    if [[ -n "${assigned[$port]:-}" ]]; then
      warn "$variable conflicts with ${assigned[$port]} on TCP port $port."
      return 1
    fi
    assigned[$port]="$variable"
  done
  if module_selected rustdesk && (( RUSTDESK_NAT_PORT + 1 != RUSTDESK_ID_PORT )); then
    warn "RUSTDESK_NAT_PORT must be one below RUSTDESK_ID_PORT for RustDesk NAT detection."
    return 1
  fi
  validate_port "$WIREGUARD_PORT" || return 1
  if module_selected wireguard; then assigned_udp["$WIREGUARD_PORT"]="WIREGUARD_PORT"; fi
  local -a udp_ports=()
  module_selected fluxer && udp_ports+=(FLUXER_VOICE_UDP_PORT)
  module_selected rustdesk && udp_ports+=(RUSTDESK_ID_PORT)
  for variable in "${udp_ports[@]}"; do
    port="${!variable}"
    validate_port "$port" || { warn "Invalid port for $variable: $port"; return 1; }
    if [[ -n "${assigned_udp[$port]:-}" ]]; then
      warn "$variable conflicts with ${assigned_udp[$port]} on UDP port $port."
      return 1
    fi
    assigned_udp[$port]="$variable"
  done
}

configure_ports() {
  local default_profile=standard
  local variable module_name protocol
  local -a custom_ports=(HTTP_PORT HTTPS_PORT SMTP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT MAILBOX_SETUP_PORT)
  ensure_port_defaults
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then default_profile=local; fi
  for module_name in ${BASM_MODULES:-basm} $BASM_PREPARED_MODULES; do
    case "$module_name" in
      lamp) variable=LAMP_PORT ;;
      uptime-kuma) variable=UPTIME_KUMA_PORT ;;
      wireguard) variable=WIREGUARD_PORT ;;
      rustdesk)
        custom_ports+=(RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT)
        continue
        ;;
      fluxer)
        for variable in FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT; do
          custom_ports+=("$variable")
        done
        continue
        ;;
      *) continue ;;
    esac
    [[ " ${custom_ports[*]} " == *" $variable "* ]] || custom_ports+=("$variable")
  done
  printf 'Port setup also prepares the ports for future full-profile modules; unselected services remain stopped.\n'
  while true; do
    PORT_PROFILE="$(prompt_value "Port setup: standard, local test range, or custom (advanced)" "$default_profile" '[[ "$1" == standard || "$1" == local || "$1" == custom ]]')"
    if [[ "$PORT_PROFILE" != custom ]]; then
      set_port_defaults "$PORT_PROFILE"
    fi
    if [[ "$PORT_PROFILE" == custom ]]; then
      for variable in "${custom_ports[@]}"; do
        printf -v "$variable" '%s' "$(prompt_value "$variable" "${!variable}" 'validate_port "$1"')"
      done
    fi
    if (BASM_MODULES="${BASM_MODULES:-basm} $BASM_PREPARED_MODULES"; validate_port_plan); then break; fi
    warn "Choose a port profile again to resolve the conflict."
  done
  for variable in "${custom_ports[@]}"; do
    protocol=tcp
    if [[ "$variable" == WIREGUARD_PORT || "$variable" == FLUXER_VOICE_UDP_PORT ]]; then protocol=udp; fi
    if port_in_use "${!variable}" "$protocol"; then
      warn "$variable (${!variable}/$protocol) is already in use on this host. Stop its current owner or rerun with custom ports."
    fi
    if [[ "$variable" == RUSTDESK_ID_PORT ]] && port_in_use "${!variable}" udp; then
      warn "$variable (${!variable}/udp) is already in use on this host."
    fi
  done
  export PORT_PROFILE HTTP_PORT HTTPS_PORT SMTP_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT \
    FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT \
    RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT MAILBOX_HOSTNAME MAILBOX_BIND_ADDRESS \
    MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT
}

validate_local_bind_address() {
  local address="$1"
  local -a octets
  local octet
  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    [[ ${#octet} -le 3 && "$octet" == "$((10#$octet))" ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  [[ "$address" == 127.0.0.1 || "${octets[0]}" == 10 ||
     ( "${octets[0]}" == 192 && "${octets[1]}" == 168 ) ||
     ( "${octets[0]}" == 172 && "${octets[1]}" -ge 16 && "${octets[1]}" -le 31 ) ]]
}

configure_local_mode() {
  DEPLOYMENT_MODE=local
  BIND_ADDRESS="${LOCAL_BIND_ADDRESS:-127.0.0.1}"
  validate_local_bind_address "$BIND_ADDRESS" || fail "Local mode requires 127.0.0.1 or a private IPv4 LAN address."
  MANAGEMENT_BIND_ADDRESS="$BIND_ADDRESS"
  BASM_ROOT="${LOCAL_BASM_ROOT:-/opt/basm-local}"
  PRIMARY_DOMAIN=localhost
  if [[ "$BIND_ADDRESS" != 127.0.0.1 ]]; then PRIMARY_DOMAIN=basm.test; fi
  ERP_URL="erp.$PRIMARY_DOMAIN"
  MAIL_URL="mail.$PRIMARY_DOMAIN"
  MAILBOX_HOSTNAME="mx.$PRIMARY_DOMAIN"
  CLOUD_URL="cloud.$PRIMARY_DOMAIN"
  FLUXER_DOMAIN="chat.$PRIMARY_DOMAIN"
  BACKUP_LOCATION="$BASM_ROOT/backups"
  export DEPLOYMENT_MODE BIND_ADDRESS BASM_ROOT PRIMARY_DOMAIN ERP_URL MAIL_URL MAILBOX_HOSTNAME CLOUD_URL FLUXER_DOMAIN BACKUP_LOCATION
}

render_homepage() {
  local destination="${BASM_RENDER_DIR:-$BASM_ROOT}" scheme=https port="$HTTPS_PORT" fluxer=""
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then scheme=http; port="$HTTP_PORT"; fi
  if module_selected fluxer; then fluxer="$FLUXER_DOMAIN"; fi
  install -d -m 755 "$destination/home" || return
  install -m 644 "$ROOT_DIR/docs/images/mascot.png" "$destination/home/mascot.png" || return
  /usr/bin/python3 "$ROOT_DIR/templates/render-homepage.py" "$ROOT_DIR/templates/home.html" \
    "$COMPANY_NAME" "$scheme" "$port" "$ERP_URL" "$CLOUD_URL" "$MAILBOX_HOSTNAME" "$fluxer" \
    > "$destination/home/index.html" || return
  chmod 644 "$destination/home/index.html"
}

render_stack() {
  local proxy_template="$ROOT_DIR/templates/traefik.yml"
  local fluxer_entrypoint=websecure fluxer_domain=""
  local destination="${BASM_RENDER_DIR:-$BASM_ROOT}"
  local compose_variables='${BASM_ROOT} ${BIND_ADDRESS} ${HTTP_PORT} ${HTTPS_PORT} ${BASM_CONTAINER_PREFIX} ${SMTP_BIND_ADDRESS} ${SMTP_PORT} ${WEB_PROTOCOL} ${BACKUP_LOCATION} ${NEXTCLOUD_TRUSTED_DOMAINS} ${MAILBOX_BIND_ADDRESS} ${MAILBOX_SETUP_BIND_ADDRESS} ${MAILBOX_SETUP_PORT} ${MAILBOX_SUBMISSION_PORT} ${MAILBOX_IMAPS_PORT} ${MAILBOX_HOSTNAME}'
  export BASM_ROOT PRIMARY_DOMAIN ERP_URL MAIL_URL CLOUD_URL MAILBOX_HOSTNAME
  export BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    WEB_PROTOCOL="${WEB_PROTOCOL:-http}"
  else
    WEB_PROTOCOL="${WEB_PROTOCOL:-https}"
  fi
  export WEB_PROTOCOL
  export NEXTCLOUD_TRUSTED_DOMAINS="${CLOUD_URL:-}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    proxy_template="$ROOT_DIR/templates/traefik-local.yml"
    NEXTCLOUD_TRUSTED_DOMAINS="$CLOUD_URL localhost 127.0.0.1"
    if [[ "$BIND_ADDRESS" != 127.0.0.1 ]]; then NEXTCLOUD_TRUSTED_DOMAINS+=" $BIND_ADDRESS"; fi
  fi
  export BASM_CONTAINER_PREFIX="${BASM_CONTAINER_PREFIX:-basm}"
  ensure_port_defaults
  if module_selected fluxer; then
    FLUXER_DOMAIN="${FLUXER_DOMAIN:-chat.$PRIMARY_DOMAIN}"
    export FLUXER_DOMAIN FLUXER_PROXY_PORT
    fluxer_domain="$FLUXER_DOMAIN"
  fi
  envsubst "$compose_variables" < "$ROOT_DIR/templates/docker-compose.yml" > "$destination/docker-compose.yml" || return
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then fluxer_entrypoint=web; fi
  envsubst '${PRIMARY_DOMAIN} ${ERP_URL} ${MAIL_URL} ${CLOUD_URL} ${BIND_ADDRESS} ${HTTPS_PORT} ${MAILBOX_HOSTNAME}' \
    < "$proxy_template" |
    /usr/bin/python3 "$ROOT_DIR/templates/render-routes.py" "$fluxer_domain" "$FLUXER_PROXY_PORT" "$fluxer_entrypoint" "$BASM_ROOT/config/traefik-custom.yml" \
      > "$destination/config/traefik.yml" || return
  local TRAEFIK_TRUSTED_IPS='[]'
  if [[ -f "$BASM_ROOT/config/traefik-edge-ip" ]]; then
    TRAEFIK_TRUSTED_IPS="$(python3 -c 'import ipaddress,json,sys; print(json.dumps([str(ipaddress.IPv4Address(open(sys.argv[1]).read().strip())) + "/32"]))' "$BASM_ROOT/config/traefik-edge-ip")" || return
  fi
  export TRAEFIK_TRUSTED_IPS
  envsubst < "$ROOT_DIR/templates/traefik-static.yml" > "$destination/config/traefik-static.yml" || return
  if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
    cat >> "$destination/config/traefik-static.yml" <<EOF

certificatesResolvers:
  letsencrypt:
    acme:
      email: "$ADMIN_EMAIL"
      storage: "/data/acme.json"
EOF
    if [[ -f "$BASM_ROOT/data/traefik/desec-token" ]]; then
      [[ -s "$BASM_ROOT/data/traefik/desec-token" && ! -L "$BASM_ROOT/data/traefik/desec-token" ]] ||
        fail "The Traefik deSEC token must be a nonempty regular file."
      (( (8#$(stat -c %a "$BASM_ROOT/data/traefik/desec-token") & 077) == 0 )) ||
        fail "The Traefik deSEC token must be private; use chmod 600."
      cat >> "$destination/config/traefik-static.yml" <<'EOF'
      dnsChallenge:
        provider: desec
        resolvers: ["1.1.1.1:53", "1.0.0.1:53"]
        propagation:
          delayBeforeChecks: 60s
          requireAllRNS: true
EOF
    else
      printf '      tlsChallenge: {}\n' >> "$destination/config/traefik-static.yml" || return
    fi
  fi
  render_homepage
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local validator="${3:-}"
  local value=""

  while true; do
    if [[ -n "$default_value" ]]; then
      read -rp "$label [$default_value] (press Enter to accept): " value
    else
      read -rp "$label: " value
    fi

    value="${value:-$default_value}"

    if [[ -z "$value" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi

    if [[ -n "$validator" ]] && ! (set -- "$value"; eval "$validator"); then
      warn "Invalid value for $label. Please try again."
      continue
    fi

    printf '%s\n' "$value"
    return 0
  done
}

prompt_ip_mode() {
  local choice
  choice="$(prompt_value "Public IP type: N = dynamic (updates deSEC), S = static" "${1:-non-static}" '[[ "${1,,}" == s || "${1,,}" == n || "${1,,}" == static || "${1,,}" == non-static ]]')" || return
  case "${choice,,}" in
    s|static) printf 'static\n' ;;
    n|non-static) printf 'non-static\n' ;;
  esac
}

wizard_section() {
  printf '\n============================================================\n%s\n============================================================\n' "$1"
}

review_wizard() {
  if [[ -t 0 && -t 1 && -n "${TERM:-}" && "$TERM" != dumb ]]; then
    printf '\033[H\033[2J'
  fi
  wizard_section "Review BASM setup"
  printf 'Company: %s\nMode: %s\nData directory: %s\n' "$COMPANY_NAME" "$DEPLOYMENT_MODE" "$BASM_ROOT"
  printf 'Administrator email: %s\nTimezone: %s\nNextcloud administrator: %s\n' "$ADMIN_EMAIL" "$TIMEZONE" "$NEXTCLOUD_ADMIN_USER"
  printf '\nDomain: %s\nERP: %s\nMail alias: %s\nMail server/admin: %s\nCloud: %s\n' \
    "$PRIMARY_DOMAIN" "$ERP_URL" "$MAIL_URL" "$MAILBOX_HOSTNAME" "$CLOUD_URL"
  printf 'Web bind address: %s\nManagement bind address: %s\n' "$BIND_ADDRESS" "$MANAGEMENT_BIND_ADDRESS"
  printf 'Public IP type: %s\nBackup destination: %s\nModules: %s\n\n' "$IP_MODE" "$BACKUP_LOCATION" "$BASM_MODULES"
  printf 'ERPNext learning examples: %s (never submitted automatically)\n' "${ERP_EXAMPLES:-no}"
  warn_backup_filesystem "$BACKUP_LOCATION"
  port_summary
  if [[ "$DEPLOYMENT_MODE" == local ]]; then
    printf '\nLocal access: HTTP on the selected bind address.\n'
  else
    printf '\nProduction web routes use public HTTPS. Mail requires DNS records and TCP 25 routing.\n'
  fi
  if module_selected fluxer; then
    printf 'Fluxer: https://%s (public chat/calls).\n' "$FLUXER_DOMAIN"
  fi
  printf '\nAccept to save these settings and begin installation.\n'
  local answer
  while true; do
    read -rp "Accept and install (A), restart guide (R), or cancel (C): " answer ||
      fail "Could not read setup confirmation; deployment settings were not saved."
    case "${answer,,}" in
      a|accept) return 0 ;;
      r|restart) return 2 ;;
      c|cancel) log "Installation cancelled; deployment settings were not saved."; exit 0 ;;
      *) warn "Enter A to accept, R to restart, or C to cancel." ;;
    esac
  done
}

warn_backup_filesystem() {
  local existing="$1" root_device backup_device
  while [[ ! -e "$existing" ]]; do existing="$(dirname "$existing")"; done
  root_device="$(findmnt --noheadings --output MAJ:MIN --target /)" ||
    fail "Could not identify the system filesystem."
  backup_device="$(findmnt --noheadings --output MAJ:MIN --target "$existing")" ||
    fail "Could not identify the backup filesystem."
  if [[ "$root_device" == "$backup_device" ]]; then
    warn "Backup destination is on the system filesystem. Disk failure would lose both the deployment and its backups."
  fi
}

select_backup_destination() {
  local default_path="$1" mounts candidates mount source choice destination
  local -a destinations=("$default_path")
  mounts="$(findmnt --list --json --output TARGET,SOURCE,FSTYPE,OPTIONS)" ||
    fail "Could not list mounted backup filesystems."
  candidates="$(jq -r '.filesystems[] |
    select((.source | startswith("/dev/")) or
      (.fstype | IN("virtiofs", "nfs", "nfs4", "cifs"))) |
    select(.target != "/" and (.target | test("^/(boot|dev|proc|sys|run)(/|$)|^/var/lib/(docker|containers)(/|$)") | not)) |
    select(.options | split(",") | index("rw")) |
    [.target, .source] | @tsv' <<< "$mounts")" ||
    fail "Could not read mounted backup filesystems."

  printf '\nBackup destination (only already-mounted disks and supported shares are listed):\n' >&2
  printf '  1) Default directory: %s\n' "$default_path" >&2
  while IFS=$'\t' read -r mount source; do
    [[ -n "$mount" ]] || continue
    validate_backup_path "$mount" || continue
    destination="${mount%/}/basm-backups"
    [[ "$destination" != "$default_path" ]] || continue
    destinations+=("$destination")
    printf '  %s) %s on %s -> %s\n' "${#destinations[@]}" "$source" "$mount" "$destination" >&2
  done <<< "$candidates"
  local custom_choice=$((${#destinations[@]} + 1))
  printf '  %s) Custom directory (e.g. an already-mounted network share)\n' "$custom_choice" >&2
  printf 'You can also enter an absolute directory path directly.\n' >&2
  printf 'No disks will be formatted or mounted. For a VM, mount host backup storage in the guest first.\n' >&2
  while true; do
    read -rp "Backup destination [1] (press Enter to accept): " choice || fail "No backup destination selection received."
    choice="${choice:-1}"
    if [[ "$choice" == /* ]] && validate_backup_path "$choice"; then
      destination="$choice"
      break
    fi
    if [[ "$choice" == "$custom_choice" ]]; then
      destination="$(prompt_value "Backup destination directory" "$default_path" 'validate_backup_path "$1"')"
      break
    fi
    if [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] && (( choice <= ${#destinations[@]} )); then
      destination="${destinations[choice-1]}"
      break
    fi
    warn "Choose one of the listed backup destinations."
  done
  warn_backup_filesystem "$destination"
  printf '%s\n' "$destination"
}

select_deployment() {
  local domain="${BASM_PRESET_DOMAIN:-}"
  if [[ -z "$domain" ]]; then
    domain="$(prompt_value "Primary domain (e.g. example.com), or 'local' for local test setup" example.com '[[ "$1" == local || "$1" == localhost || "$1" == 127.0.0.1 ]] || validate_domain "$1"')"
  fi
  LOCAL_MODE=false
  BASM_ROOT="${PRODUCTION_BASM_ROOT:-/opt/basm}"
  if [[ "$domain" == local || "$domain" == localhost || "$domain" == 127.0.0.1 ]]; then
    LOCAL_MODE=true
    BASM_ROOT="${LOCAL_BASM_ROOT:-/opt/basm-local}"
  fi
  BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]]; then acquire_operation_lock; fi
  if [[ -f "$BASM_ENV_FILE" ]]; then
    local selected_root="$BASM_ROOT"
    read_deployment_settings
    [[ "$BASM_ROOT" == "$selected_root" ]] || fail "Saved deployment path does not match the selected installation."
  fi
  if [[ "$LOCAL_MODE" == false ]]; then
    if [[ "${PRIMARY_DOMAIN:-}" != "$domain" ]]; then
      unset ERP_URL MAIL_URL CLOUD_URL MAILBOX_HOSTNAME FLUXER_DOMAIN
    fi
    PRIMARY_DOMAIN="$domain"
  fi
}

print_module_menu() {
  local index=1 module_name label mark
  printf '\nBASM installation menu\n\n'
  for module_name in basm lamp wireguard fluxer vaultwarden uptime-kuma keepass rustdesk; do
    case "$module_name" in
      basm) label='BASM Core (required)' ;;
      lamp) label='LAMP' ;;
      wireguard) label='WireGuard' ;;
      fluxer) label='Fluxer' ;;
      vaultwarden) label='Vaultwarden (deprecated; unavailable for new installs)' ;;
      uptime-kuma) label='Uptime Kuma' ;;
      keepass) label='KeePassXC credential manager' ;;
      rustdesk) label='RustDesk Server OSS' ;;
    esac
    mark=' '
    if [[ "$module_name" == basm ]] || module_selected "$module_name"; then mark='✓'; fi
    printf '%s) [%s] %s\n' "$index" "$mark" "$label"
    index=$((index + 1))
  done
  printf '\nSelect modules by number (1-8), separated by spaces, or enter "full" for\n'
  printf 'All supported modules (including Fluxer, KeePassXC, and RustDesk).\n'
  printf 'Full requires production mode. Leave blank to keep the checked modules.\n'
  printf 'Example: 2 4 6\n'
}

select_modules() {
  local input=""
  local -a selected=()
  local -A map=(
    [1]="basm"
    [2]="lamp"
    [3]="wireguard"
    [4]="fluxer"
    [5]="vaultwarden"
    [6]="uptime-kuma"
    [7]="keepass"
    [8]="rustdesk"
  )

  print_module_menu
  read -rp "Module selection: " input

  if [[ -z "$input" ]]; then
    BASM_MODULES="${BASM_MODULES:-basm}"
    module_selected basm || BASM_MODULES="basm $BASM_MODULES"
    return
  fi
  if [[ "$input" == full ]]; then
    BASM_MODULES="$BASM_FULL_MODULES"
    return
  fi

  local choice
  for choice in $input; do
    if [[ "$choice" =~ ^[1-8]$ ]]; then
      if [[ "$choice" == 5 ]]; then
        warn "Vaultwarden is deprecated and unavailable for new installs; select KeePassXC instead."
      elif [[ ! " ${selected[*]} " =~ " ${map[$choice]} " ]]; then
        selected+=("${map[$choice]}")
      fi
    else
      warn "Skipping invalid module choice: $choice"
    fi
  done

  if [[ ${#selected[@]} -eq 0 ]]; then
    BASM_MODULES="basm"
    return
  fi

  if [[ ! " ${selected[*]} " =~ " basm " ]]; then
    selected=("basm" "${selected[@]}")
  fi

  BASM_MODULES="$(printf '%s ' "${selected[@]}")"
  BASM_MODULES="${BASM_MODULES% }"
}

write_env_file() {
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    WEB_PROTOCOL="${WEB_PROTOCOL:-http}"
  else
    WEB_PROTOCOL="${WEB_PROTOCOL:-https}"
  fi
  mkdir -p "$(dirname "$BASM_ENV_FILE")"
  cat > "$BASM_ENV_FILE" <<EOF
DEPLOYMENT_MODE="$DEPLOYMENT_MODE"
BIND_ADDRESS="$BIND_ADDRESS"
MANAGEMENT_BIND_ADDRESS="$MANAGEMENT_BIND_ADDRESS"
BASM_CONTAINER_PREFIX="$BASM_CONTAINER_PREFIX"
PORT_PROFILE="$PORT_PROFILE"
COMPANY_NAME="$COMPANY_NAME"
PRIMARY_DOMAIN="$PRIMARY_DOMAIN"
ADMIN_EMAIL="$ADMIN_EMAIL"
TIMEZONE="$TIMEZONE"
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
SSH_PORT=$SSH_PORT
LAMP_PORT=$LAMP_PORT
UPTIME_KUMA_PORT=$UPTIME_KUMA_PORT
WIREGUARD_PORT=$WIREGUARD_PORT
RUSTDESK_NAT_PORT=$RUSTDESK_NAT_PORT
RUSTDESK_ID_PORT=$RUSTDESK_ID_PORT
RUSTDESK_RELAY_PORT=$RUSTDESK_RELAY_PORT
FLUXER_PROXY_PORT=$FLUXER_PROXY_PORT
FLUXER_VOICE_TCP_PORT=$FLUXER_VOICE_TCP_PORT
FLUXER_VOICE_UDP_PORT=$FLUXER_VOICE_UDP_PORT
ERP_URL="$ERP_URL"
ERP_EXAMPLES="${ERP_EXAMPLES:-no}"
MAIL_URL="$MAIL_URL"
CLOUD_URL="$CLOUD_URL"
MAILBOX_HOSTNAME="$MAILBOX_HOSTNAME"
IP_MODE="${IP_MODE:-non-static}"
DESEC_TOKEN="${DESEC_TOKEN:-}"
BACKUP_LOCATION="$BACKUP_LOCATION"
BASM_ROOT="$BASM_ROOT"
BASM_MODULES="$BASM_MODULES"
DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD"
ERP_ADMIN_PASSWORD="$ERP_ADMIN_PASSWORD"
NEXTCLOUD_ADMIN_USER="$NEXTCLOUD_ADMIN_USER"
NEXTCLOUD_ADMIN_PASSWORD="$NEXTCLOUD_ADMIN_PASSWORD"
NEXTCLOUD_DB_PASSWORD="$NEXTCLOUD_DB_PASSWORD"
SMTP_BIND_ADDRESS="$SMTP_BIND_ADDRESS"
SMTP_PORT=$SMTP_PORT
WEB_PROTOCOL="$WEB_PROTOCOL"
MAILBOX_BIND_ADDRESS="$MAILBOX_BIND_ADDRESS"
MAILBOX_SETUP_BIND_ADDRESS="$MAILBOX_SETUP_BIND_ADDRESS"
MAILBOX_SETUP_PORT=$MAILBOX_SETUP_PORT
MAILBOX_SUBMISSION_PORT=$MAILBOX_SUBMISSION_PORT
MAILBOX_IMAPS_PORT=$MAILBOX_IMAPS_PORT
RESTIC_PASSWORD="$RESTIC_PASSWORD"
FLUXER_DOMAIN="$FLUXER_DOMAIN"
EOF
  chmod 600 "$BASM_ENV_FILE"
}

run_wizard() {
  log "Launching BASM wizard"

  local variable status
  local -a settings=(
    LOCAL_MODE LOCAL_BIND_ADDRESS BASM_ROOT BASM_ENV_FILE DEPLOYMENT_MODE BIND_ADDRESS
    MANAGEMENT_BIND_ADDRESS BASM_CONTAINER_PREFIX PORT_PROFILE COMPANY_NAME PRIMARY_DOMAIN
    ADMIN_EMAIL TIMEZONE NEXTCLOUD_ADMIN_USER BACKUP_LOCATION ERP_URL ERP_EXAMPLES MAIL_URL CLOUD_URL
    IP_MODE DESEC_TOKEN BASM_MODULES HTTP_PORT HTTPS_PORT SSH_PORT SMTP_BIND_ADDRESS SMTP_PORT
    MAILBOX_HOSTNAME MAILBOX_BIND_ADDRESS MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT
    MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT
    LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT
    FLUXER_DOMAIN FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT WEB_PROTOCOL
    DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD
  )
  local -A initial=()
  for variable in "${settings[@]}"; do
    if [[ -v "$variable" ]]; then initial["$variable"]="${!variable}"; fi
  done
  while true; do
    for variable in "${settings[@]}"; do
      if [[ -v "initial[$variable]" ]]; then
        printf -v "$variable" '%s' "${initial[$variable]}"
      else
        unset "$variable"
      fi
    done
    collect_wizard_settings
    if review_wizard; then break; else status=$?; fi
    [[ "$status" == 2 ]] || fail "Could not confirm setup."
  done

  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(generate_password)}"
  ERP_ADMIN_PASSWORD="${ERP_ADMIN_PASSWORD:-$(generate_password)}"
  NEXTCLOUD_ADMIN_PASSWORD="${NEXTCLOUD_ADMIN_PASSWORD:-$(generate_password)}"
  NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-$(generate_password)}"
  RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(generate_password)}"

  write_env_file
  read_deployment_settings
  export DEPLOYMENT_MODE BIND_ADDRESS BASM_CONTAINER_PREFIX COMPANY_NAME PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE HTTP_PORT HTTPS_PORT SSH_PORT ERP_URL MAIL_URL CLOUD_URL MAILBOX_HOSTNAME BACKUP_LOCATION BASM_ROOT BASM_MODULES DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD WEB_PROTOCOL SMTP_BIND_ADDRESS SMTP_PORT MAILBOX_BIND_ADDRESS MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT RESTIC_PASSWORD
}

collect_wizard_settings() {
  wizard_section "1/5 - Deployment"
  select_deployment

  if [[ "${LOCAL_MODE:-false}" == true ]]; then
    LOCAL_BIND_ADDRESS="$(prompt_value "Local bind address (localhost or private LAN IPv4)" localhost '[[ "$1" == localhost ]] || validate_local_bind_address "$1"')"
    if [[ "$LOCAL_BIND_ADDRESS" == localhost ]]; then LOCAL_BIND_ADDRESS=127.0.0.1; fi
    configure_local_mode
    BASM_CONTAINER_PREFIX=basm-local
    SMTP_BIND_ADDRESS=127.0.0.1
    SMTP_PORT=2525
  else
    DEPLOYMENT_MODE=production
    BIND_ADDRESS=0.0.0.0
    BASM_CONTAINER_PREFIX=basm
    SMTP_BIND_ADDRESS=0.0.0.0
    SMTP_PORT=25
  fi
  MAILBOX_HOSTNAME="mx.$PRIMARY_DOMAIN"
  MAILBOX_BIND_ADDRESS="$BIND_ADDRESS"
  MAILBOX_SETUP_BIND_ADDRESS=127.0.0.1
  FLUXER_DOMAIN="chat.$PRIMARY_DOMAIN"

  wizard_section "2/5 - Organization and backups"
  COMPANY_NAME="$(prompt_value "Company Name" "${COMPANY_NAME:-BASM Business}" 'validate_company_name "$1"')"
  local email_validator='validate_email "$1"' default_email="${ADMIN_EMAIL:-admin@example.com}"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then
    email_validator='validate_production_email "$1"'
    validate_production_email "$default_email" || default_email=""
  fi
  local attempt
  ADMIN_EMAIL=""
  for attempt in 1 2 3; do
    ADMIN_EMAIL="$(prompt_value "Administrator Email (certificate account)" "$default_email" "$email_validator")"
    [[ -n "$ADMIN_EMAIL" ]] && break
    warn "A real administrator email address is required for production certificates."
  done
  [[ -n "$ADMIN_EMAIL" ]] || fail "No valid administrator email address was provided."
  TIMEZONE="$(prompt_value "Timezone (IANA name, e.g. Europe/Stockholm; list with timedatectl list-timezones)" "${TIMEZONE:-Etc/UTC}" 'validate_timezone "$1"')"
  NEXTCLOUD_ADMIN_USER="$(prompt_value "Nextcloud administrator username" "${NEXTCLOUD_ADMIN_USER:-basm-admin}" 'validate_admin_username "$1"')"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then BACKUP_LOCATION="${BACKUP_LOCATION:-/var/backups/basm}"; fi
  BACKUP_LOCATION="$(select_backup_destination "${BACKUP_LOCATION:-$BASM_ROOT/backups}")"

  SSH_PORT="${SSH_PORT:-22}"
  wizard_section "3/5 - Service addresses and DNS"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then
    ERP_URL="$(prompt_value "ERP URL" "${ERP_URL:-erp.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    MAIL_URL="$(prompt_value "Mail alias URL" "${MAIL_URL:-mail.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    CLOUD_URL="$(prompt_value "Cloud URL" "${CLOUD_URL:-cloud.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    IP_MODE="$(prompt_ip_mode "${IP_MODE:-non-static}")"
    if [[ "$IP_MODE" == non-static ]]; then
      local token=""
      for attempt in 1 2 3; do
        read -rsp "deSEC API token${DESEC_TOKEN:+ (blank keeps the saved token)}: " token
        printf '\n' >&2
        token="${token:-${DESEC_TOKEN:-}}"
        validate_desec_token "$token" && break
        warn "Enter a valid deSEC token with DNS update rights for $PRIMARY_DOMAIN."
        token=""
      done
      [[ -n "$token" ]] || fail "A valid deSEC token is required for a non-static IP install."
      DESEC_TOKEN="$token"
    else
      DESEC_TOKEN=""
    fi
  else
    IP_MODE=static
    DESEC_TOKEN=""
  fi

  wizard_section "4/5 - Modules"
  select_modules
  printf '\nOptional ERPNext learning examples: labelled sample records and module walkthroughs.\n'
  printf 'Created after ERPNext first-run setup; transactions stay in Draft. No postings or payments.\n'
  local examples
  examples="$(prompt_value "Include ERPNext learning examples? (yes/no)" "${ERP_EXAMPLES:-no}" '[[ "${1,,}" == yes || "${1,,}" == no || "${1,,}" == y || "${1,,}" == n ]]')" || return
  case "${examples,,}" in
    yes|y) ERP_EXAMPLES=yes ;;
    no|n) ERP_EXAMPLES=no ;;
  esac
  if [[ "$DEPLOYMENT_MODE" == local ]] && module_selected fluxer; then
    fail "Fluxer requires production HTTPS and public network access; it cannot be selected in BASM local mode."
  fi
  FLUXER_DOMAIN="${FLUXER_DOMAIN:-chat.$PRIMARY_DOMAIN}"
  wizard_section "5/5 - Ports"
  configure_ports
  if port_in_use "$SMTP_PORT"; then
    warn "Mail server SMTP port $SMTP_PORT/tcp is already in use. Choose an available port or stop its current owner."
  fi

  WEB_PROTOCOL=http
  if [[ "$DEPLOYMENT_MODE" != local ]]; then WEB_PROTOCOL=https; fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings || return
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list || return
    fi
    # APT verifies repositories as _apt, including on retries after a failed install.
    chmod 0644 /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list || return
    ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return
  fi
}

configure_system() {
  log "Configuring Debian installation"

  if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
    local host memory_kib
    local -a service_hosts=("$ERP_URL" "$MAIL_URL" "$CLOUD_URL" "$MAILBOX_HOSTNAME")
    module_selected fluxer && service_hosts+=("$FLUXER_DOMAIN")
    for host in "${service_hosts[@]}"; do
      if ! getent ahostsv4 "$host" >/dev/null 2>&1; then
        warn "DNS for $host does not resolve yet; public routes and TLS issuance will not be ready."
      fi
    done
    memory_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    if (( memory_kib < 2097152 )) || (( $(nproc) < 2 )); then
      warn "Mail service performance may be limited on a host with less than 2 GiB RAM or 2 CPU cores."
    fi
    warn "Production mail requires public MX/SPF/DKIM/DMARC records and inbound/outbound TCP port 25."
  fi

  # shellcheck disable=SC2086
  ensure_packages $BASM_REQUIRED_PACKAGES

  ensure_docker || fail "Could not install Docker."

  ensure_dir "$BASM_ROOT"
  ensure_dir "$BASM_ROOT/config"
  prepare_stalwart_storage || fail "Cannot prepare Stalwart configuration storage."
  ensure_dir "$BASM_ROOT/data"
  ensure_dir "$BASM_ROOT/data/db-backups"
  chmod 700 "$BASM_ROOT/data/db-backups"
  ensure_dir "$BASM_ROOT/logs"
  check_backup_filesystem || fail "Could not access the saved backup filesystem."
  ensure_dir "$BACKUP_LOCATION"
  ensure_dir "$BACKUP_LOCATION/restic"
  ensure_dir "$OUTPUT_DIR"
  if [[ "${BASM_ENTRYPOINT:-false}" == true && -f "$BASM_ROOT/docker-compose.yml" ]]; then
    initialize_repository || fail "Could not open the existing backup repository."
    install_runtime || fail "Could not install operator tools."
    update_deployment "$ROOT_DIR" || fail "Existing deployment update failed; installation stopped."
  else
    cp "$ROOT_DIR/templates/erpnext-create-site.sh" "$BASM_ROOT/config/erpnext-create-site.sh"
    chmod 755 "$BASM_ROOT/config/erpnext-create-site.sh"
  fi
  render_stack || fail "Cannot render the BASM stack."
  prepare_full_profile

  log "System setup complete"
}

prepare_full_profile() {
  local module_name
  for module_name in $BASM_PREPARED_MODULES; do
    module_selected "$module_name" && continue
    (
      source "$MODULES_DIR/$module_name.sh"
      module_install "$BASM_ROOT/config/prepared-modules/$module_name"
    ) || fail "Could not prepare configuration for '$module_name'."
  done
}

install_selected_modules() {
  local selected_modules="${BASM_MODULES:-basm}"

  if [[ -z "$selected_modules" ]]; then
    selected_modules="basm"
  fi

  log "Installing selected modules: $selected_modules"

  local module_name
  for module_name in $selected_modules; do
    run_module_install "$module_name"
  done
  install_auto_updates
  install_ddns_updater
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]]; then
    initialize_repository || fail "Could not initialize the backup repository."
    backup_deployment || fail "Initial complete backup failed."
  fi
}

update_cron_file() {
  local identifier
  identifier="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  printf '%s/basm-%s' "${BASM_CRON_DIR:-/etc/cron.d}" "$identifier"
}

fluxer_backup_cron_file() {
  local identifier
  identifier="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  printf '%s/basm-fluxer-backup-%s' "${BASM_CRON_DIR:-/etc/cron.d}" "$identifier"
}

ddns_cron_file() {
  local identifier
  identifier="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  printf '%s/basm-ddns-%s' "${BASM_CRON_DIR:-/etc/cron.d}" "$identifier"
}

# Dynamic-IP installs check the public IPv4 every 4 hours and update deSEC.
install_ddns_updater() (
  umask 077
  local maintenance_dir="$BASM_ROOT/maintenance" cron_file
  cron_file="$(ddns_cron_file "$BASM_ROOT")"
  if [[ "${DEPLOYMENT_MODE:-production}" == local || "${IP_MODE:-non-static}" != non-static ]]; then
    rm -f "$cron_file" "$maintenance_dir/ddns-update.sh"
    return 0
  fi
  [[ "$BASM_ROOT" != *%* ]] || fail "Deployment path cannot contain a percent sign."
  install_runtime || fail "Cannot install the DNS maintenance helpers."
  install -d -m 700 "$maintenance_dir" "$BASM_ROOT/logs" || fail "Cannot create maintenance directories."
  install -m 700 "$ROOT_DIR/templates/ddns-update.sh" "$maintenance_dir/ddns-update.sh" || fail "Cannot install the deSEC DNS updater."
  mkdir -p "$(dirname "$cron_file")" || fail "Cannot create cron directory."
  cat > "$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 */4 * * * root /bin/bash "$maintenance_dir/ddns-update.sh" "$BASM_ROOT"
EOF
  chmod 644 "$cron_file" || fail "Cannot set cron permissions."
  systemctl enable --now cron || fail "Cannot enable the DNS update scheduler."
  /bin/bash "$maintenance_dir/ddns-update.sh" "$BASM_ROOT" || warn "Initial deSEC DNS update failed; see $BASM_ROOT/logs/ddns.log. Cron retries every 4 hours."
  log "deSEC DNS updates scheduled every 4 hours for the dynamic public IP."
)

run_module_install() {
  local module_name="$1"
  local script_path="$MODULES_DIR/${module_name}.sh"

  ensure_port_defaults
  (BASM_MODULES="${BASM_MODULES:-basm} $module_name"; validate_port_plan) || fail "Resolve port conflicts in the setup wizard before installing this module."

  if [[ ! -f "$script_path" ]]; then
    fail "Module '$module_name' was requested but no installer script exists at $script_path"
  fi

  log "Running module installer: $module_name"
  local prepared_dir="$BASM_ROOT/config/prepared-modules/$module_name"
  local module_dir="$BASM_ROOT/modules/$module_name"
  if [[ -d "$prepared_dir" && ! -e "$module_dir" ]]; then
    ensure_dir "$BASM_ROOT/modules"
    mv "$prepared_dir" "$module_dir" || fail "Could not activate prepared configuration for '$module_name'."
  fi
  unset -f module_install module_start module_update
  source "$script_path"
  if declare -F module_install >/dev/null; then
    module_install || return
    if declare -F module_start >/dev/null && [[ "${BASM_SKIP_START:-false}" != true ]]; then
      module_start
    fi
  else
    fail "Module '$module_name' does not expose a module_install function."
  fi
}

run_module_update() {
  local module_name="$1" script_path
  [[ "$module_name" == fluxer ]] || return 0
  script_path="${MODULES_DIR:-$ROOT_DIR/modules}/${module_name}.sh"
  [[ -f "$script_path" ]] || fail "Unknown module: $module_name"
  unset -f module_install module_start module_update
  source "$script_path"
  if declare -F module_update >/dev/null; then
    module_update "$BASM_ROOT/modules/$module_name"
  fi
}

load_deployment_env() {
  local selected_root="$BASM_ROOT"
  [[ -f "$BASM_ENV_FILE" ]] || fail "No BASM configuration was found at $BASM_ENV_FILE. Run the full installer for this environment first."
  read_deployment_settings
  [[ "${1:-}" == --recovery || "$BASM_ROOT" == "$selected_root" ]] ||
    fail "Saved deployment path does not match the selected installation."
  validate_backup_path "$BASM_ROOT" && [[ "$BASM_ROOT" != / ]] || fail "Invalid BASM deployment path."
  validate_backup_path "$BACKUP_LOCATION" || fail "Invalid backup destination."
  [[ "$(realpath -m "$BASM_ROOT")" == "$BASM_ROOT" && "$(realpath -m "$BACKUP_LOCATION")" == "$BACKUP_LOCATION" ]] ||
    fail "Deployment and backup paths must be canonical, without symlinks."
  case "$BASM_ROOT/" in "$BACKUP_LOCATION/"*) fail "Backups cannot contain the live deployment." ;; esac
  if [[ "${LOCAL_MODE:-false}" == true ]]; then
    [[ "${DEPLOYMENT_MODE:-}" == local ]] || fail "Expected a local environment configuration."
    validate_local_bind_address "$BIND_ADDRESS" || fail "Unsafe local bind address."
  fi
  ensure_port_defaults
  FLUXER_DOMAIN="${FLUXER_DOMAIN:-chat.$PRIMARY_DOMAIN}"
}

add_modules_to_selection() {
  local module_name
  for module_name in "$@"; do
    module_selected "$module_name" || BASM_MODULES="${BASM_MODULES:-basm} $module_name"
  done
  export BASM_MODULES
}

module_port_variable() {
  case "$1" in
    lamp) printf '%s' LAMP_PORT ;;
    uptime-kuma) printf '%s' UPTIME_KUMA_PORT ;;
    wireguard) printf '%s' WIREGUARD_PORT ;;
    rustdesk) printf '%s' RUSTDESK_ID_PORT ;;
    fluxer) printf '%s' FLUXER_PROXY_PORT ;;
  esac
}

module_port_variables() {
  case "$1" in
    lamp) printf '%s\n' LAMP_PORT ;;
    uptime-kuma) printf '%s\n' UPTIME_KUMA_PORT ;;
    wireguard) printf '%s\n' WIREGUARD_PORT ;;
    rustdesk) printf '%s\n' RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT ;;
    fluxer) printf '%s\n' FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT ;;
  esac
}

# Adds optional modules without recreating the core stack or its credentials.
# Module-specific prerequisites are installed as needed; cached images are reused.
upgrade_modules() {
  local module_name variable protocol
  local -a added=()
  [[ -f "$BASM_ROOT/docker-compose.yml" ]] || fail "No core BASM stack was found at $BASM_ROOT. Run the full installer first."
  for module_name in "$@"; do
    if [[ "$module_name" == vaultwarden ]] && ! module_selected vaultwarden; then
      fail "Vaultwarden is deprecated for new installs. Select KeePassXC instead."
    fi
    [[ -f "$MODULES_DIR/$module_name.sh" ]] || fail "Unknown module: $module_name"
    if [[ "${DEPLOYMENT_MODE:-production}" == local && "$module_name" == fluxer ]]; then
      fail "Fluxer requires production HTTPS and cannot be selected in local mode."
    fi
    module_selected "$module_name" || added+=("$module_name")
  done
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]] &&
      grep -Eq '^  (db-backup|restic-backup):' "$BASM_ROOT/docker-compose.yml"; then
    initialize_repository || fail "Could not open the existing backup repository."
    install_runtime || fail "Could not install operator tools."
    update_deployment "$ROOT_DIR" || fail "Existing deployment update failed; module installation stopped."
  fi
  add_modules_to_selection "$@"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]] && module_selected fluxer; then
    fail "Fluxer requires production HTTPS and public network access; it cannot be selected in BASM local mode."
  fi

  while ! validate_port_plan; do
    warn "The current port plan conflicts with the requested modules. Choose new module ports."
    for module_name in "${added[@]}"; do
      while IFS= read -r variable; do
        [[ -n "$variable" ]] || continue
        printf -v "$variable" '%s' "$(prompt_value "$variable" "${!variable}" 'validate_port "$1"')"
      done < <(module_port_variables "$module_name")
    done
    PORT_PROFILE=custom
  done
  for module_name in "${added[@]}"; do
    while IFS= read -r variable; do
      [[ -n "$variable" ]] || continue
      protocol=tcp
      if [[ "$variable" == WIREGUARD_PORT || "$variable" == FLUXER_VOICE_UDP_PORT ]]; then protocol=udp; fi
      if port_in_use "${!variable}" "$protocol"; then
        warn "$variable (${!variable}/$protocol) is already in use on this host."
      fi
      if [[ "$variable" == RUSTDESK_ID_PORT ]] && port_in_use "${!variable}" udp; then
        warn "$variable (${!variable}/udp) is already in use on this host."
      fi
    done < <(module_port_variables "$module_name")
  done
  export PORT_PROFILE LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT FLUXER_PROXY_PORT \
    FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT \
    RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT

  write_env_file
  for module_name in "$@"; do
    [[ "$module_name" == basm ]] && continue
    run_module_install "$module_name" || fail "Module '$module_name' failed to install."
  done
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]]; then
    refresh_routes || fail "Could not refresh module routes."
    basm_stack restart traefik || fail "Could not reload module routes."
  fi
  install_auto_updates
  install_ddns_updater
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]]; then
    backup_deployment || fail "Post-install module backup failed."
  fi
  write_summary
  log "Installed modules: $BASM_MODULES"
}

upgrade_to_full() {
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    fail "The full profile includes Fluxer, which requires production HTTPS. Promote to production first, or add local-compatible modules individually."
  fi
  log "Upgrading $BASM_ROOT to the full BASM profile"
  # shellcheck disable=SC2086
  upgrade_modules $BASM_FULL_MODULES
}

run_module_action_for_root() (
  local root="$1" module_name="$2" action="$3" action_function
  [[ -f "$root/config/basm.env" ]] || return 0
  BASM_ENV_FILE="$root/config/basm.env"
  read_deployment_settings
  BASM_ROOT="$root"
  module_selected "$module_name" || return 0
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$module_name.sh"
  action_function="module_$action"
  "$action_function"
)

# Stops a deployment's containers without removing data or volumes.
stop_deployment() {
  local root="$1" compose_file
  command -v docker >/dev/null 2>&1 || return 0
  run_module_action_for_root "$root" fluxer stop || warn "Could not stop Fluxer at $root"
  while IFS= read -r compose_file; do
    [[ "$(basename "$(dirname "$compose_file")")" == fluxer ]] && continue
    module_compose "$compose_file" down --remove-orphans || warn "Could not stop $compose_file"
  done < <(module_compose_files "$root")
  if [[ -f "$root/docker-compose.yml" ]]; then
    log "Stopping BASM Docker stack at $root"
    basm_compose -f "$root/docker-compose.yml" --env-file "$root/config/basm.env" down --remove-orphans || warn "Could not stop the core stack at $root"
  fi
}

start_deployment() {
  local root="$1" compose_file
  command -v docker >/dev/null 2>&1 || return 0
  if [[ -f "$root/docker-compose.yml" ]]; then
    BASM_ROOT="$root" BASM_ENV_FILE="$root/config/basm.env" basm_stack up -d --remove-orphans || warn "Could not restart the core stack at $root"
  fi
  while IFS= read -r compose_file; do
    [[ "$(basename "$(dirname "$compose_file")")" == fluxer ]] && continue
    module_compose "$compose_file" up -d --remove-orphans || warn "Could not restart $compose_file"
  done < <(module_compose_files "$root")
  run_module_action_for_root "$root" fluxer start || warn "Could not restart Fluxer at $root"
}

# Stops every BASM stack under a root, removes its containers, networks and
# named volumes, then deletes the directory. Docker images are kept so a later
# install can reuse them without downloading.
purge_deployment() {
  local root="$1" compose_file
  [[ -n "$root" && "$root" != / ]] || fail "Refusing to purge an empty or root path."
  rm -f "$(update_cron_file "$root")" "$(backup_cron_file "$root")" "$(check_cron_file "$root")" "$(examples_cron_file "$root")" "$(ddns_cron_file "$root")" "$(fluxer_backup_cron_file "$root")"
  run_module_action_for_root "$root" fluxer uninstall || fail "Could not remove Fluxer at $root; deployment data was kept."
  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r compose_file; do
      log "Stopping module stack $compose_file"
      module_compose "$compose_file" down -v --remove-orphans || warn "Could not stop $compose_file"
    done < <(module_compose_files "$root")
    if [[ -f "$root/docker-compose.yml" ]]; then
      log "Stopping BASM Docker stack at $root"
      basm_compose -f "$root/docker-compose.yml" --env-file "$root/config/basm.env" down -v --remove-orphans || warn "Could not stop the core stack at $root"
    fi
  fi
  rm -rf "$root"
}

# Replaces a local test deployment with a fresh production deployment.
# Organization settings and the module selection carry over; secrets, data,
# URLs, and ports do not. Packages and cached images are reused.
promote_to_production() {
  local local_root="${LOCAL_BASM_ROOT:-/opt/basm-local}"
  local production_root="${PRODUCTION_BASM_ROOT:-/opt/basm}"
  local domain="" answer local_backup variable

  [[ -f "$local_root/config/basm.env" ]] || fail "No local BASM installation was found at $local_root."
  if [[ "${BASM_ENTRYPOINT:-false}" == true ]]; then
    BASM_ROOT="$local_root"
    acquire_operation_lock
    exec 8>&9
    unset BASM_LOCK_ROOT
  fi
  if [[ -f "$production_root/docker-compose.yml" ]]; then
    fail "A production stack already exists at $production_root. Use ./update.sh or uninstall it before promoting."
  fi
  BASM_ENV_FILE="$local_root/config/basm.env"
  read_deployment_settings
  [[ "${DEPLOYMENT_MODE:-}" == local ]] || fail "$local_root does not contain a local test configuration."
  local_backup="${BACKUP_LOCATION:-$local_root/backups}"

  while [[ -z "$domain" ]]; do
    domain="$(prompt_value "Production primary domain (e.g. example.com)" "" 'validate_domain "$1"')"
  done

  printf '\nPromoting the local test install to production on %s:\n' "$domain"
  printf -- '- The local stack, its data, and its credentials under %s are permanently removed.\n' "$local_root"
  printf -- '- A fresh production stack with new credentials is created under %s.\n' "$production_root"
  printf -- '- Company, admin email, time zone, Nextcloud admin name, and modules (%s) carry over.\n' "${BASM_MODULES:-basm}"
  printf -- '- Installed packages and cached Docker images are reused; nothing is upgraded.\n\n'
  read -rp "Type 'promote' to continue: " answer
  [[ "$answer" == promote ]] || { log "Promotion cancelled."; return 1; }

  for variable in DEPLOYMENT_MODE BIND_ADDRESS BASM_CONTAINER_PREFIX PORT_PROFILE HTTP_PORT HTTPS_PORT \
    LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT FLUXER_DOMAIN FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT SMTP_PORT SMTP_BIND_ADDRESS ERP_URL MAIL_URL CLOUD_URL \
    MAILBOX_HOSTNAME MAILBOX_BIND_ADDRESS MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT \
    RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT \
    BACKUP_LOCATION PRIMARY_DOMAIN DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD \
    NEXTCLOUD_DB_PASSWORD WEB_PROTOCOL RESTIC_PASSWORD; do
    unset "$variable"
  done

  BASM_PRESET_DOMAIN="$domain"
  run_wizard
  unset BASM_PRESET_DOMAIN
  [[ "$DEPLOYMENT_MODE" == production && "$BASM_ROOT" == "$production_root" ]] || fail "Production configuration was not created."

  # Stop (but keep) the local install so its data survives a failed setup.
  stop_deployment "$local_root"
  if ! ( configure_system && install_selected_modules ); then
    warn "Production setup failed. Rolling back to the local test install."
    purge_deployment "$production_root"
    start_deployment "$local_root"
    fail "Promotion failed; the local install at $local_root was restored. Fix the reported error and rerun ./install.sh --promote."
  fi

  log "Removing local test deployment at $local_root"
  purge_deployment "$local_root"
  if [[ "$local_backup" != "$local_root" && "$local_backup" != "$local_root"/* && -d "$local_backup" ]]; then
    warn "Local backups at $local_backup were kept. Delete them manually when no longer needed."
  fi
  rm -f "$OUTPUT_DIR/local-installation-summary.txt"
  write_summary
  log "Promotion to production completed."
}

port_summary() {
  printf 'Port Profile: %s\n' "${PORT_PROFILE:-custom}"
  printf 'Proxy HTTP: %s/tcp\nProxy HTTPS: %s/tcp\n' "$HTTP_PORT" "$HTTPS_PORT"
  printf 'Mail server SMTP: %s/tcp\n' "$SMTP_PORT"
  printf 'Mailbox SMTP submission: %s/tcp\nMailbox IMAP over TLS: %s/tcp\n' \
    "$MAILBOX_SUBMISSION_PORT" "$MAILBOX_IMAPS_PORT"
  printf 'Mailbox first-run setup (loopback only): %s/tcp\n' "$MAILBOX_SETUP_PORT"
  printf 'Host SSH (unchanged): %s/tcp\n' "${SSH_PORT:-22}"
  printf 'Reusable install settings: %s/config/basm.env (root-only)\n' "$BASM_ROOT"
  local module_name variable protocol host="$BIND_ADDRESS"
  if [[ "$host" == 0.0.0.0 ]]; then host="$PRIMARY_DOMAIN"; fi
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) printf 'LAMP: http://%s:%s (private management listener)\n' "${MANAGEMENT_BIND_ADDRESS:-$host}" "$LAMP_PORT" ;;
      uptime-kuma) printf 'Uptime Kuma: http://%s:%s (private management listener)\n' "${MANAGEMENT_BIND_ADDRESS:-$host}" "$UPTIME_KUMA_PORT" ;;
      wireguard) printf 'WireGuard: %s/udp (server and peer1 configs in %s/modules/wireguard; not started)\n' "$WIREGUARD_PORT" "$BASM_ROOT" ;;
      rustdesk)
        printf 'RustDesk ID server: %s:%s (TCP/UDP); NAT test: %s/tcp\n' "$host" "$RUSTDESK_ID_PORT" "$RUSTDESK_NAT_PORT"
        printf 'RustDesk relay server: %s:%s (TCP)\nPublic key file: %s/modules/rustdesk/data/id_ed25519.pub\n' "$host" "$RUSTDESK_RELAY_PORT" "$BASM_ROOT"
        ;;
      fluxer)
        printf 'Fluxer: https://%s:%s (proxy listener %s/tcp)\n' "$FLUXER_DOMAIN" "$HTTPS_PORT" "$FLUXER_PROXY_PORT"
        if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
          printf 'Fluxer voice media: %s/tcp and %s/udp\n' "$FLUXER_VOICE_TCP_PORT" "$FLUXER_VOICE_UDP_PORT"
        fi
        ;;
    esac
  done
  for module_name in $BASM_PREPARED_MODULES; do
    module_selected "$module_name" && continue
    variable="$(module_port_variable "$module_name")"
    [[ -n "$variable" ]] || continue
    protocol=tcp
    if [[ "$module_name" == wireguard ]]; then protocol=udp; fi
    printf 'Prepared %s port (not active): %s/%s; config: %s/config/prepared-modules/%s\n' \
      "$module_name" "${!variable}" "$protocol" "$BASM_ROOT" "$module_name"
  done
}

# Strips the primary domain so the result is a deSEC subname (empty for the apex).
dns_subname() {
  local name="${1%.}"
  if [[ "$name" == "$PRIMARY_DOMAIN" ]]; then
    printf ''
  else
    printf '%s' "${name%."$PRIMARY_DOMAIN"}"
  fi
}

# Writes copy-paste DNS records for self-hosted Stalwart mail.
write_dns_records() {
  local file="$1" d="$PRIMARY_DOMAIN"
  local a_ttl=3600
  local erp_sub cloud_sub mail_sub fluxer_sub
  local mailbox_host="${MAILBOX_HOSTNAME:-mx.$PRIMARY_DOMAIN}"
  if [[ "${IP_MODE:-non-static}" == non-static ]]; then a_ttl=300; fi
  erp_sub="$(dns_subname "$ERP_URL")"
  cloud_sub="$(dns_subname "$CLOUD_URL")"
  mail_sub="$(dns_subname "$MAIL_URL")"
  fluxer_sub="$(dns_subname "${FLUXER_DOMAIN:-chat.$PRIMARY_DOMAIN}")"
  cat > "$file" <<EOF
DNS records for $d
====================
Publish these at your DNS provider (deSEC subnames are relative to $d;
"@" is the zone apex). Use DNS-only records and no AAAA records.
PUBLIC_IP is the server's public IPv4 address.

Core hostnames (A)
  @                 A      PUBLIC_IP
  ${erp_sub:-@}     A      PUBLIC_IP
  ${cloud_sub:-@}   A      PUBLIC_IP
  ${mail_sub:-@}    A      PUBLIC_IP   (Mail alias; redirects to $mailbox_host)
$(if module_selected fluxer; then printf '  %-17s A      PUBLIC_IP   (Fluxer chat: %s)\n' "${fluxer_sub:-@}" "$FLUXER_DOMAIN"; fi)
  mx                A      PUBLIC_IP   (mail server: $mailbox_host)
  autoconfig        CNAME  $mailbox_host.
  autodiscover      CNAME  $mailbox_host.
  mta-sts           CNAME  $mailbox_host.
  ua-auto-config    CNAME  $mailbox_host.
$(if [[ "${IP_MODE:-non-static}" == non-static ]]; then printf '  The A records above are kept current by the BASM DDNS job; do not edit them by hand.\n'; fi)

Mail domain $d (Stalwart receives and sends user mail)
  @                 MX     10 $mailbox_host.
  @                 TXT    "v=spf1 mx -all"
  mx                TXT    "v=spf1 a -all"
  _dmarc            TXT    "v=DMARC1; p=none; rua=mailto:postmaster@$d"
  _jmap._tcp        SRV    0 1 443 $mailbox_host.

DKIM
  After setup, publish the complete DNS zone file shown for $d in Stalwart.
  It includes the current DKIM keys and service-discovery records. Merge its
  SPF and DMARC entries with existing records; never publish duplicate SPF
  records or replace other TXT records used by the domain.

If you also keep a separate fixed record elsewhere, note that only ONE SPF TXT
record may exist at the domain apex. Replace any older SPF record instead of
adding a second. Reverse DNS (PTR) is controlled by the IP address-range owner;
deSEC does not manage it. Without PTR control, outbound delivery may be less
reliable, but BASM can still host and send mail.

One-step setup for deSEC
------------------------
Paste the following into a terminal on any computer. It asks for a deSEC API
token, detects the public IPv4, and creates or updates the records
above, except TXT records. Add or merge the SPF, DMARC and DKIM TXT records
manually so existing verification and policy records are not overwritten.
This one-time command does not save its token; BASM's dynamic updater uses the
token entered in the installer.

read -rsp 'deSEC API token: ' TOKEN; echo
PUBLIC_IP="\$(curl -4 -fsS https://api.ipify.org)"
BODY="\$(cat <<DNSJSON
[
 {"subname":"","type":"A","ttl":$a_ttl,"records":["\$PUBLIC_IP"]},
 {"subname":"$erp_sub","type":"A","ttl":$a_ttl,"records":["\$PUBLIC_IP"]},
 {"subname":"$cloud_sub","type":"A","ttl":$a_ttl,"records":["\$PUBLIC_IP"]},
 {"subname":"$mail_sub","type":"A","ttl":$a_ttl,"records":["\$PUBLIC_IP"]},
$(if module_selected fluxer; then printf ' {"subname":"%s","type":"A","ttl":%s,"records":["$PUBLIC_IP"]},\n' "$fluxer_sub" "$a_ttl"; fi)
 {"subname":"mx","type":"A","ttl":$a_ttl,"records":["\$PUBLIC_IP"]},
 {"subname":"autoconfig","type":"CNAME","ttl":3600,"records":["$mailbox_host."]},
 {"subname":"autodiscover","type":"CNAME","ttl":3600,"records":["$mailbox_host."]},
 {"subname":"mta-sts","type":"CNAME","ttl":3600,"records":["$mailbox_host."]},
 {"subname":"ua-auto-config","type":"CNAME","ttl":3600,"records":["$mailbox_host."]},
 {"subname":"_jmap._tcp","type":"SRV","ttl":3600,"records":["0 1 443 $mailbox_host."]},
 {"subname":"","type":"MX","ttl":3600,"records":["10 $mailbox_host."]}
]
DNSJSON
)"
printf 'header = "Authorization: Token %s"\\n' "\$TOKEN" | curl -fsS -K - -X PATCH \\
  -H 'Content-Type: application/json' -d "\$BODY" \\
  "https://desec.io/api/v1/domains/$d/rrsets/" -o /dev/null -w 'HTTP %{http_code}\\n'
unset TOKEN

A result of HTTP 200 means the records were saved. Dynamic-IP installs use a
300-second TTL for A records so address changes propagate sooner. DNS changes
can take a few minutes to appear. Verify with:
  dig +short MX $d
  dig +short TXT $d
  dig +short A $mailbox_host
EOF
}

write_handover() (
  umask 077
  local handover_dir="$BASM_ROOT/handover"
  local scheme=https web_port="$HTTPS_PORT"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    scheme=http
    web_port="$HTTP_PORT"
  fi
  local home_host="$PRIMARY_DOMAIN"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then home_host="home.$PRIMARY_DOMAIN"; fi
  [[ ! -L "$handover_dir" ]] || fail "Handover directory must not be a symbolic link."
  mkdir -p "$handover_dir" || fail "Cannot create handover directory."
  chmod 700 "$handover_dir" || fail "Cannot protect handover directory."
  local document
  for document in for-the-user.txt for-it.txt; do
    [[ ! -L "$handover_dir/$document" ]] || fail "Handover document must not be a symbolic link."
  done

  if module_selected keepass; then
    local keepass_master_password
    keepass_master_password="$(sync_keepass)" || fail "Cannot generate the KeePass credential handover."
    cat > "$handover_dir/for-the-user.txt" <<EOF
For the User
============
Business: $COMPANY_NAME
Installation: ${DEPLOYMENT_MODE:-production}
Prepared: $(date -u +'%Y-%m-%d %H:%M:%S UTC')

PRIVATE: This document contains the master password for your credential database.

START HERE
Open $scheme://$home_host:$web_port for links to your business services.
Each service requires its own sign-in.

YOUR KEEPASS ACCESS
Open this database with KeePassXC (installed on the server), or another
KeePass-compatible application on your computer:
Database: $BASM_ROOT/vaults/admin/credentials.kdbx
Master password: $keepass_master_password
No database username is required. This admin vault is for the owner/IT only.
If IT configured a private share, open the canonical database directly there;
do not download another editable working copy. Otherwise ask IT for secure access.
Use separate shared and personal vaults for employees; never share this admin vault.

The BASM group contains the service addresses, administrator logins, database
credentials, backup encryption password, and generated private keys.
Entries start with the installation values. Record password changes in KeePass;
installer reruns preserve existing entries rather than resetting your edits.
Ask IT to record any manually created monitoring, server, router, domain-provider,
and internet-provider accounts in the database too.
KeePass is a desktop application, not a web service, and opens no network port.

AUTOMATIC MAINTENANCE
BASM attempts application updates on January 1 and July 1 at 03:00 (server time).
Leave the server on. Services may briefly be unavailable.

IF SOMETHING DOES NOT WORK
Check your internet connection, then ask your IT contact. Do not reinstall or
run uninstall.sh to fix a sign-in problem; removing data can destroy records.
IT contact name / phone: ________________________________________________

Need professional support? Scandinavian Hacking can help you troubleshoot
problems and keep your business systems running. Contact us at:
https://scandinavianhacking.se/
EOF
  else
  cat > "$handover_dir/for-the-user.txt" <<EOF
For the User
============
Business: $COMPANY_NAME
Installation: ${DEPLOYMENT_MODE:-production}
Prepared: $(date -u +'%Y-%m-%d %H:%M:%S UTC')

PRIVATE: This document contains passwords. Keep it in a password manager or
print it and lock it away. Do not email it or put it in a shared cloud folder.
Ask your installer to hand you this document securely before they leave.

START HERE
Open $scheme://$home_host:$web_port for links to your business services.
Each service requires its own sign-in.

YOUR SIGN-IN DETAILS
Open these addresses in your web browser. Passwords are case-sensitive.

Business accounts and operations (ERPNext)
Address: $scheme://$ERP_URL:$web_port
Username: Administrator
Initial password: $ERP_ADMIN_PASSWORD

Learning examples selected: ${ERP_EXAMPLES:-no}
If selected, finish ERPNext's first-run wizard, then wait up to five minutes.
In ERPNext, search for Note and open "BASM Example: Start Here".
Examples are fictional; never submit or send them.

Files and sharing (Nextcloud)
Address: $scheme://$CLOUD_URL:$web_port
Username: $NEXTCLOUD_ADMIN_USER
Initial password: $NEXTCLOUD_ADMIN_PASSWORD

Email administration (Stalwart)
Address: $scheme://$MAILBOX_HOSTNAME:$web_port/admin
Mail server: $MAILBOX_HOSTNAME
IT creates the first administrator and mailbox during first-time setup. The
password is displayed only once by the setup wizard; have IT record it securely.

THUNDERBIRD SETTINGS (after IT creates your mailbox)
Email address and username: your complete email address
Incoming server: $MAILBOX_HOSTNAME, IMAP, port 993, SSL/TLS
Outgoing server: $MAILBOX_HOSTNAME, SMTP, port 465, SSL/TLS
Use the mailbox password for both. Do not use the Stalwart administrator login.

These are administrator accounts. Ask IT to create a personal account for each
employee; do not share these administrator passwords for everyday work.
Passwords shown here are the installation values. If changed in an application,
record the new value in your password manager. BASM cannot read it back, and
rerunning the installer does not reset it or update this document from the app.

OTHER ACCOUNTS
EOF
  if module_selected uptime-kuma; then
    cat >> "$handover_dir/for-the-user.txt" <<EOF
Monitoring (Uptime Kuma): http://$MANAGEMENT_BIND_ADDRESS:$UPTIME_KUMA_PORT
Loopback addresses require an IT-provided SSH tunnel when using another computer.
No account is generated. IT must complete first-time setup on the private
network and record the chosen username and password in your password manager.
EOF
  fi
  if module_selected fluxer; then
    cat >> "$handover_dir/for-the-user.txt" <<EOF
Community chat and calls (Fluxer): https://$FLUXER_DOMAIN
The first Fluxer administrator account is created interactively during setup.
IT must record its login details securely and create named accounts for users.
EOF
  fi
  if module_selected lamp; then
    printf 'Website (LAMP): http://%s:%s - private listener; no login is created.\n' "$MANAGEMENT_BIND_ADDRESS" "$LAMP_PORT" >> "$handover_dir/for-the-user.txt"
  fi
  if module_selected wireguard; then
    cat >> "$handover_dir/for-the-user.txt" <<EOF
Remote access (WireGuard): not started automatically; IT must enable it first.
The private connection file is $BASM_ROOT/modules/wireguard/peer1.conf.
It is a key, not a username/password. Never share it between employees.
EOF
  fi
  cat >> "$handover_dir/for-the-user.txt" <<EOF
Server, router, domain-provider and internet-provider accounts are not created
by BASM. Ask IT to record those existing accounts in your password manager.
IT contact name / phone: ________________________________________________

AUTOMATIC MAINTENANCE
BASM attempts application updates on January 1 and July 1 at 03:00, according
to the server's clock. Leave the server on. Services may briefly be unavailable.
IT should check the update log afterward and handle urgent security fixes sooner.
Ask IT to disable this schedule if your business requires approved manual updates.
Compatible application channels are refreshed automatically; major releases
and exact-version pins still need IT review.

BACKUPS AND RECOVERY (FOR YOUR IT HELPER)
Daily encrypted backups: $BACKUP_LOCATION/restic
Backup encryption password: $RESTIC_PASSWORD
No backup username is required for this local repository.

Technical database accounts, not browser logins:
ERPNext database server: erp-db; username: root; password: $DB_ROOT_PASSWORD
Nextcloud database server: nextcloud-db; username: root; password: $DB_ROOT_PASSWORD
Nextcloud application database: nextcloud; username: nextcloud; password: $NEXTCLOUD_DB_PASSWORD
Other application-managed keys remain in the protected application data and
configuration backups. Do not change database passwords in this document.

IF SOMETHING DOES NOT WORK
Check your internet connection, then ask your IT contact. Do not reinstall or
run uninstall.sh to fix a sign-in problem; removing data can destroy records.

Need professional support? Scandinavian Hacking can help you troubleshoot
problems and keep your business systems running. Contact us at:
https://scandinavianhacking.se/
EOF
  fi

  if module_selected fluxer; then
    cat >> "$handover_dir/for-the-user.txt" <<EOF

Fluxer (self-hosted chat)
Address: $scheme://$FLUXER_DOMAIN:$web_port
The first administrator account is created interactively during installation.
Have IT record its login details securely; BASM does not store them here.
EOF
  fi

  if module_selected rustdesk; then
    local rustdesk_host="$PRIMARY_DOMAIN"
    if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then rustdesk_host="$BIND_ADDRESS"; fi
    cat >> "$handover_dir/for-the-user.txt" <<EOF

Remote desktop (RustDesk Server OSS)
In each RustDesk client's Network settings, set:
ID server: $rustdesk_host:$RUSTDESK_ID_PORT
Relay server: $rustdesk_host:$RUSTDESK_RELAY_PORT
Key: contents of $BASM_ROOT/modules/rustdesk/data/id_ed25519.pub
The key is generated at first server start. Ask IT to provide it securely.
Leave API server blank; no web console or administrator account is installed.
Clients must use the server key. Remote access still requires approval or a
strong unattended-access password on each client device.
EOF
  fi

  cat > "$handover_dir/for-it.txt" <<EOF
For IT
======
Business: $COMPANY_NAME
Mode: ${DEPLOYMENT_MODE:-production}
Deployment directory: $BASM_ROOT
Selected modules: ${BASM_MODULES:-basm}
Credentials: $handover_dir/for-the-user.txt (private)

1. HAND OVER THE ACCOUNTS
On the server, open the private user document with:
  sudo less "$handover_dir/for-the-user.txt"
Deliver it securely to the owner, not through ordinary email or a shared folder.
Record your support contact details. Create named employee accounts and enable
two-factor authentication where available. Record changed passwords separately;
these documents contain initial values, not live passwords from applications.
$(if module_selected keepass; then printf '%s\n' \
  'KeePass is enabled: all service credentials are in vaults/admin/credentials.kdbx.' \
  'Restrict this admin vault to owner/IT. Use separate shared and personal employee vaults.' \
  'Record Fluxer administrator credentials in KeePass after interactive setup.' \
  'Record account changes and manually created logins in KeePass.'; fi)

2. IDENTIFY THE SERVER AND ROUTER
Run these commands at the Debian server's terminal:
  hostname -I
  ip route show default
The private server IPv4 usually starts with 192.168., 10., or 172.16.-172.31.
Do not use a Docker bridge address. The default route's 'via' address is usually
the router. On a computer on the same network, open that router address in a
browser. Sign in using the router's existing administrator account.
In LAN / DHCP / Address Reservation, reserve the server's private address for
its network card. Save it. Router menu names differ by manufacturer.
Server private IPv4: __________________ Router address: __________________
EOF
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    cat >> "$handover_dir/for-it.txt" <<EOF

3. LOCAL TESTING ONLY: DO NOT FORWARD ANY ROUTER PORTS
Bind address: $BIND_ADDRESS
Nextcloud: http://$BIND_ADDRESS:$HTTP_PORT
Start page: http://$home_host:$HTTP_PORT
ERPNext: http://$ERP_URL:$HTTP_PORT
Email administration: http://$MAILBOX_HOSTNAME:$HTTP_PORT/admin
With a localhost binding, use the browser on the server itself.
For LAN testing, rerun the wizard and select the server's private IPv4 as the
bind address. On each client, map these names to that address in private DNS
or its hosts file (Linux: /etc/hosts; Windows: C:\Windows\System32\drivers\etc\hosts):
  $BIND_ADDRESS $home_host $ERP_URL $MAIL_URL $MAILBOX_HOSTNAME $CLOUD_URL$(if module_selected fluxer; then printf ' %s' "$FLUXER_DOMAIN"; fi)
Use the selected private IPv4 instead of localhost in that entry.
HTTP is unencrypted: use test data and a trusted network only.
SMTP is loopback-only on $SMTP_PORT; public mail and HTTPS are not configured.
EOF
    if module_selected fluxer; then
      cat >> "$handover_dir/for-it.txt" <<EOF
Fluxer: http://$FLUXER_DOMAIN:$HTTP_PORT
Voice ports bind to $BIND_ADDRESS on TCP $FLUXER_VOICE_TCP_PORT and UDP $FLUXER_VOICE_UDP_PORT.
Do not forward these ports on a router in local mode.
EOF
    fi
  else
    cat >> "$handover_dir/for-it.txt" <<EOF

3. CONNECT THE DOMAIN
In the router's Internet / WAN status, find the public IPv4. If it is private,
starts with 100.64.-100.127., or differs from your internet-facing public IP,
port forwarding alone will not work through carrier-grade NAT or an upstream
router you cannot configure. Use a reachable public IPv4 and confirm that the
network path allows inbound AND outbound TCP 25. A dynamic IPv4 is supported.
At the domain provider, create the DNS records in:
  $handover_dir/dns-records.txt
It lists the A, MX, SPF, DMARC and mail records and, for deSEC, a paste-ready
command that creates them. The A records point to the public IPv4 for:
  $PRIMARY_DOMAIN
  $ERP_URL
  $MAIL_URL
  $CLOUD_URL
$(if module_selected fluxer; then printf '  %s\n' "$FLUXER_DOMAIN"; fi)
  mx.$PRIMARY_DOMAIN
$(if module_selected fluxer; then printf '  %s\n' "$FLUXER_DOMAIN"; fi)
Use DNS-only records, not a CDN proxy, during setup. Do not publish AAAA records
unless IPv6 routing and firewall rules have also been configured and tested.$(if [[ "${IP_MODE:-non-static}" == non-static ]]; then printf '\n%s' \
  "This install uses a dynamic IP: every 4 hours cron updates these deSEC" \
  "records if the public IPv4 changed. Log: $BASM_ROOT/logs/ddns.log"; fi)

4. FORWARD THE ROUTER PORTS
Open NAT / Port Forwarding / Virtual Server. Add one rule per line below.
For a direct setup, every rule targets the reserved private BASM IPv4 from step
2. If BASM runs in a VM behind a separate DEN edge, do not add direct HTTP/HTTPS
rules to this table: public TCP 80/443 go to DEN and its edge routes web traffic
to BASM. TCP 25 goes directly to the BASM VM. Never forward the same public
port to both machines.
Service        Protocol    External port    Internal (server) port
HTTP           TCP         $HTTP_PORT               $HTTP_PORT
HTTPS          TCP         $HTTPS_PORT              $HTTPS_PORT
Mail SMTP      TCP         25               $SMTP_PORT
$(if module_selected fluxer; then printf 'Fluxer media   TCP         %s               %s\nFluxer media   UDP         %s               %s\n' "$FLUXER_VOICE_TCP_PORT" "$FLUXER_VOICE_TCP_PORT" "$FLUXER_VOICE_UDP_PORT" "$FLUXER_VOICE_UDP_PORT"; fi)
$(if module_selected rustdesk; then printf 'RustDesk NAT   TCP         %s               %s\nRustDesk ID    TCP/UDP     %s               %s\nRustDesk relay TCP         %s               %s\n' "$RUSTDESK_NAT_PORT" "$RUSTDESK_NAT_PORT" "$RUSTDESK_ID_PORT" "$RUSTDESK_ID_PORT" "$RUSTDESK_RELAY_PORT" "$RUSTDESK_RELAY_PORT"; fi)
Optional mail-client access from outside the LAN/VPN:
Mailbox SMTP   TCP         465              $MAILBOX_SUBMISSION_PORT
Mailbox IMAP   TCP         993              $MAILBOX_IMAPS_PORT
Add these rules only when off-network mail-client access is intended. For
LAN/VPN-only clients, keep these ports private and use private DNS and routing.
If HTTP uses a custom port, ALSO forward external TCP 80 to internal $HTTP_PORT.
If HTTPS uses a custom port, ALSO forward external TCP 443 to internal $HTTPS_PORT.
These additional rules allow normal browser access, HTTPS redirects, and
Let's Encrypt HTTP certificate validation. Do not add a duplicate rule if the
selected port is already 80 or 443. Internet mail delivery requires external
TCP 25. The loopback-only first-run mailbox setup port must not be forwarded.
Save/apply the rules. The URLs in the user document use the selected web ports;
the standard public ports also work with the additional rules above.
If the server firewall is enabled, permit these selected internal ports too.
Do not disable the firewall. Docker-published ports can bypass UFW rules;
verify reachability and filtering from outside the network.
Do not forward databases, Redis, Docker, monitoring, or router administration.
Do not forward SSH ($SSH_PORT) by default. Prefer a configured VPN for support.
LAMP and Uptime Kuma have no BASM-managed TLS or access control; keep their
ports private and restrict them on the host as well as at the router.
$(if module_selected fluxer; then printf 'Fluxer voice requires TCP %s and UDP %s forwarded to the server for calls.\n' "$FLUXER_VOICE_TCP_PORT" "$FLUXER_VOICE_UDP_PORT"; fi)

5. FINISH MAIL SETUP
Open the Stalwart first-run setup page through an SSH tunnel:
  ssh -L $MAILBOX_SETUP_PORT:127.0.0.1:$MAILBOX_SETUP_PORT <server-user>@<server-address>
Then open http://127.0.0.1:$MAILBOX_SETUP_PORT on that computer. Read the
temporary setup login from the container log:
  sudo docker logs ${BASM_CONTAINER_PREFIX}-stalwart-mail
Choose $MAILBOX_HOSTNAME as the server hostname and $PRIMARY_DOMAIN as the
mail domain. Enable Stalwart's automatic TLS certificate for the mail host.
Complete setup, restart the container, then open
https://$MAILBOX_HOSTNAME/admin. The setup wizard shows the permanent
administrator password only once; store it privately.

Stalwart admin sign-in uses OAuth metadata bound to the canonical HTTPS
hostname https://$MAILBOX_HOSTNAME. Do not sign in through localhost, an IP
address or the mail alias; those origins can fail with "Unknown client id."
Wait until a trusted certificate is valid, then sign in at
https://$MAILBOX_HOSTNAME/admin and create the owner's mailbox. From
Management -> Domains, publish the complete generated DNS zone file, merging
SPF and DMARC with existing records. Confirm that
autoconfig, autodiscover, mta-sts and ua-auto-config resolve to
$MAILBOX_HOSTNAME before expecting a valid certificate. Do not bypass
certificate warnings. Reverse DNS (PTR) is controlled by the IP address-range
owner; BASM and deSEC do not change it. Without PTR control, outbound delivery
may be less reliable, but inbound mail and the rest of the service still work.

To send invoices from ERPNext, create a dedicated Stalwart account for the
sender address, then add an outgoing Email Account in ERPNext using
$MAILBOX_HOSTNAME, port 465, SSL/TLS, and that account's credentials. Do not
reuse the Stalwart administrator login.

For production, in Settings -> Network -> Listeners add an HTTPS proxy listener:
name https-proxy, HTTP protocol, bind 0.0.0.0:8443, implicit TLS enabled, and
override proxy trusted networks set only to 172.31.255.2. BASM Traefik sends
PROXY protocol v2 over its isolated mail-proxy network.

Optional production delivery trace: in Stalwart, open Management -> Emails ->
Delivery tests, enter a private external recipient address, and run the test.
It contacts the recipient server but sends no message. Check the DNS and
DNSSEC errors in the trace; a successful trace does not prove DNSSEC validation
for every domain. For DNSSEC errors, check Stalwart's configured DNS resolver
is reachable, passes DNSSEC records, and supports TCP or TLS.

Test a message from Thunderbird to an unrelated external mailbox, reply, and
confirm both delivery directions plus SPF/DKIM/DMARC results. Then send a test
ERPNext invoice email. Do not promise working mail until DNS, provider
restrictions, and delivery are checked.
EOF
  fi
  if module_selected rustdesk; then
    cat >> "$handover_dir/for-it.txt" <<EOF

RUSTDESK CLIENT SETUP AND RECOVERY
Configure clients using the ID/relay endpoints in the user document and the
contents of $BASM_ROOT/modules/rustdesk/data/id_ed25519.pub (after first start).
Keep WebSocket ports 21118/21119 closed; this setup supports desktop clients.
Test registration and a forced-relay session between two client devices.
The complete BASM backup includes $BASM_ROOT/modules/rustdesk/data with the
services stopped for consistency. Protect id_ed25519 (private key); never share it.
Reruns preserve this directory; uninstall and local-to-production promotion
delete it. Promotion generates a new key, so reconfigure clients afterwards.
EOF
  fi
  cat >> "$handover_dir/for-it.txt" <<EOF

6. CHECK BEFORE LEAVING
Inspect the services with the installed operator tools:
  sudo basm --root "$BASM_ROOT" status
  sudo basm --root "$BASM_ROOT" check
  sudo basm --root "$BASM_ROOT" logs
One-shot initializer containers should exit successfully (code 0). Investigate
unhealthy containers, restart loops, and nonzero exits before handing over.
Open each service URL and actually sign in. In production, test public URLs
using mobile data with Wi-Fi off. Use https://$ERP_URL, https://$CLOUD_URL,
https://$MAILBOX_HOSTNAME$(if module_selected fluxer; then printf ' and https://%s' "$FLUXER_DOMAIN"; fi) when external 443 maps to the selected server HTTPS port.
Do not dismiss certificate warnings. DNS or port changes can take time;
recheck DNS and Traefik logs if certificates are not issued.
If Uptime Kuma is selected, complete its first-run account setup privately.
$(if module_selected fluxer; then printf 'Fluxer is managed by rexctl under %s/modules/fluxer. Confirm the owner can sign in to %s and test voice calls from an external network over TCP %s and UDP %s.\n' "$BASM_ROOT" "$FLUXER_DOMAIN" "$FLUXER_VOICE_TCP_PORT" "$FLUXER_VOICE_UDP_PORT"; fi)
WireGuard only generates files; it is NOT an active VPN. Follow the WireGuard
documentation to install/enable a server and create a separate peer per person.
Only after enabling it, forward UDP $WIREGUARD_PORT to the server's same port
for production use, and test the peer from outside. Never do this in local mode.

7. CHECK BACKUPS AND RECORD SUPPORT DETAILS
Read docs/backup.md in the BASM checkout for backup and restore commands.
Restores require a new staging directory; they do not overwrite live data.
Record router, DNS provider and server administrator accounts
in the owner's password manager. BASM cannot supply their existing passwords.
Never attach the environment file or user document to a public support ticket.
Rerunning installation regenerates these handovers from saved BASM settings;
it does not discover changed application passwords or manually added accounts.
8. AUTOMATIC UPDATES
Installed updater: $BASM_ROOT/maintenance/update.sh
Schedule: January 1 and July 1 at 03:00, server time (cron; server must be on).
Cron file: $(update_cron_file "$BASM_ROOT")
Log: $BASM_ROOT/logs/automatic-updates.log
Both scheduled and manual updates require fresh database dumps and a complete
encrypted snapshot before applying images. Apps pause briefly for consistency.
Images are resolved to immutable digests; Nextcloud and database major changes
are gated. An interrupted update blocks retries until repaired.
There is no automatic rollback. Failures are recorded locally; configure the
optional HTTPS webhook in config/alert-webhook for external notifications.
Missed cron runs are not replayed. Scheduled updates refuse daytime execution
(06:00-24:00). They do not upgrade Debian packages or fetch new BASM releases.
Review major releases and exact-version pins; apply urgent fixes separately.
To disable automatic runs persistently:
  sudo touch "$BASM_ROOT/config/disable-auto-updates"
To re-enable them:
  sudo rm "$BASM_ROOT/config/disable-auto-updates"
For quarterly runs, edit the cron month field from 1,7 to 1,4,7,10. Installer
reruns restore the six-month schedule but keep the disable file if present.
Manual updates: sudo basm --root "$BASM_ROOT" update
Manual updates also create their own complete pre-update snapshot.
Troubleshooting: docs/troubleshooting.md in the checkout.
EOF
  if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
    [[ ! -L "$handover_dir/dns-records.txt" ]] || fail "Handover document must not be a symbolic link."
    write_dns_records "$handover_dir/dns-records.txt" || fail "Cannot write DNS records."
    chmod 600 "$handover_dir/dns-records.txt" || fail "Cannot protect handover documents."
  fi
  chmod 600 "$handover_dir/for-the-user.txt" "$handover_dir/for-it.txt" || fail "Cannot protect handover documents."
)

credential_summary() {
  if module_selected keepass; then
    printf '%s\n' "- Service credentials: $BASM_ROOT/vaults/admin/credentials.kdbx" \
      "- KeePass access: $BASM_ROOT/handover/for-the-user.txt (private)"
  else
    printf '%s\n' '- ERPNext user: Administrator' "- Nextcloud user: $NEXTCLOUD_ADMIN_USER" \
      "- Email administrator address: $MAILBOX_HOSTNAME" "- All initial login details: $BASM_ROOT/handover/for-the-user.txt (private)"
  fi
  printf '%s\n' "- Setup and network guide: $BASM_ROOT/handover/for-it.txt"
}

write_summary() {
  local summary_file="$OUTPUT_DIR/installation-summary.txt"
  local modules_list="${BASM_MODULES:-basm}"

  write_handover || fail "Could not write private handover documents."
  log "Private handover: $BASM_ROOT/handover/for-the-user.txt and $BASM_ROOT/handover/for-it.txt (deliver securely to the owner)."

  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    summary_file="$OUTPUT_DIR/local-installation-summary.txt"
    cat > "$summary_file" <<EOF
BASM Local Installation Summary
===============================
Bind Address: $BIND_ADDRESS
Data Directory: $BASM_ROOT
Installed Modules: $modules_list

$(port_summary)
Local routes use HTTP only; the HTTPS mapping is reserved, not TLS-enabled.

HTTP URLs (no public DNS or certificates required):
- Start page: http://home.$PRIMARY_DOMAIN:$HTTP_PORT
- Cloud: http://$BIND_ADDRESS:$HTTP_PORT
- Cloud: http://$CLOUD_URL:$HTTP_PORT
- ERP: http://$ERP_URL:$HTTP_PORT
- Email administration: http://$MAILBOX_HOSTNAME:$HTTP_PORT/admin

Initial login details:
$(credential_summary)

For LAN clients, map home.$PRIMARY_DOMAIN, $ERP_URL, $MAIL_URL, $MAILBOX_HOSTNAME
and $CLOUD_URL to $BIND_ADDRESS in each client's hosts file or private DNS.
Local access uses HTTP on $BIND_ADDRESS:$HTTP_PORT.
Local mode initializes ERPNext, Nextcloud and Stalwart. SMTP binds only to loopback port $SMTP_PORT; the Stalwart first-run setup listener is also loopback-only on port $MAILBOX_SETUP_PORT. Internet mail delivery requires a production domain and DNS records.
Restic encrypts daily backups to $BACKUP_LOCATION/restic.
LAMP and Uptime Kuma start automatically when selected; WireGuard generates configuration only.
Add local-compatible modules: sudo ./install.sh --module <name> (choose local)
The full profile requires production mode because it includes Fluxer.
Promote to production: sudo ./install.sh --promote
Backup Location: $BACKUP_LOCATION
EOF
    log "Summary written to $summary_file"
    return
  fi

  cat > "$summary_file" <<EOF
BASM Installation Summary
========================

Company Name: $COMPANY_NAME
Primary Domain: $PRIMARY_DOMAIN
Admin Email: $ADMIN_EMAIL
Timezone: $TIMEZONE

Installed Modules:
- $modules_list

URLs:
- Start page: https://$PRIMARY_DOMAIN:$HTTPS_PORT
- ERP: https://$ERP_URL:$HTTPS_PORT
- Email administration: https://$MAILBOX_HOSTNAME:$HTTPS_PORT/admin
- Mail server: $MAILBOX_HOSTNAME
- Cloud: https://$CLOUD_URL:$HTTPS_PORT

Initial login details:
$(credential_summary)

Ports:
$(port_summary)

Backup Location:
- $BACKUP_LOCATION

DNS Records Required:
- A record for $PRIMARY_DOMAIN -> Public IP
- A record for $ERP_URL -> Public IP
- A record for $MAIL_URL -> Public IP
- A record for $MAILBOX_HOSTNAME -> Public IP
- A record for $CLOUD_URL -> Public IP
$(if module_selected fluxer; then printf '%s\n' "- A record for $FLUXER_DOMAIN -> Public IP"; fi)
- MX, SPF, DKIM, and DMARC records for Stalwart

Router Port Forwarding Required:
- Forward TCP $HTTP_PORT and $HTTPS_PORT to the same server ports
- Also forward public TCP 80 -> $HTTP_PORT and TCP 443 -> $HTTPS_PORT if custom
- Forward public TCP 25 -> $SMTP_PORT for Stalwart mail delivery
- For mail clients outside the LAN/VPN, forward public TCP 465 -> $MAILBOX_SUBMISSION_PORT and TCP 993 -> $MAILBOX_IMAPS_PORT
- Keep 465/993 private for LAN/VPN-only clients and resolve $MAILBOX_HOSTNAME to the BASM LAN address there
- Do not expose SSH by default; see the private For IT guide for setup steps

Post-installation Checklist:
[ ] Point DNS A record to public IP
[ ] Forward ports $HTTP_PORT and $HTTPS_PORT on the router
[ ] Test outgoing mail
[ ] Store admin credentials securely
[ ] Verify backup completion
[ ] Confirm the provider permits inbound and outbound TCP port 25

Generated at: $(date -u +'%Y-%m-%d %H:%M:%S UTC')
EOF

  log "Summary written to $summary_file"
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/operations.sh"
