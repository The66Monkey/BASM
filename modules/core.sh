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

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9.-]+\.)+[a-zA-Z]{2,}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

ensure_port_defaults() {
  local default_http=80 default_https=443 default_lamp=8080 default_kuma=3001 default_wireguard=51820
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    default_http=18080 default_https=18443 default_lamp=18081 default_kuma=18301 default_wireguard=18520
  fi
  HTTP_PORT="${HTTP_PORT:-$default_http}"
  HTTPS_PORT="${HTTPS_PORT:-$default_https}"
  LAMP_PORT="${LAMP_PORT:-$default_lamp}"
  UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-$default_kuma}"
  WIREGUARD_PORT="${WIREGUARD_PORT:-$default_wireguard}"
  SSH_PORT="${SSH_PORT:-22}"
  export HTTP_PORT HTTPS_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT SSH_PORT
}

set_port_defaults() {
  HTTP_PORT=80
  HTTPS_PORT=443
  LAMP_PORT=8080
  UPTIME_KUMA_PORT=3001
  WIREGUARD_PORT=51820
  if [[ "$1" == local ]]; then
    HTTP_PORT=18080
    HTTPS_PORT=18443
    LAMP_PORT=18081
    UPTIME_KUMA_PORT=18301
    WIREGUARD_PORT=18520
  fi
}

validate_port_plan() {
  local -A assigned=(["${SSH_PORT:-22}"]="host SSH")
  local variable module_name port
  local -a tcp_ports=(HTTP_PORT HTTPS_PORT)
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) tcp_ports+=(LAMP_PORT) ;;
      uptime-kuma) tcp_ports+=(UPTIME_KUMA_PORT) ;;
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
  validate_port "$WIREGUARD_PORT" || return 1
}

configure_ports() {
  local default_profile=standard
  local variable module_name protocol
  local -a custom_ports=(HTTP_PORT HTTPS_PORT)
  ensure_port_defaults
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then default_profile=local; fi
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) custom_ports+=(LAMP_PORT) ;;
      uptime-kuma) custom_ports+=(UPTIME_KUMA_PORT) ;;
      wireguard) custom_ports+=(WIREGUARD_PORT) ;;
    esac
  done
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
    if validate_port_plan; then break; fi
    warn "Choose a port profile again to resolve the conflict."
  done
  for variable in "${custom_ports[@]}"; do
    protocol=tcp
    if [[ "$variable" == WIREGUARD_PORT ]]; then protocol=udp; fi
    if port_in_use "${!variable}" "$protocol"; then
      warn "$variable (${!variable}/$protocol) is already in use on this host. Stop its current owner or rerun with custom ports."
    fi
  done
  export PORT_PROFILE HTTP_PORT HTTPS_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT
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
  BASM_ROOT="${LOCAL_BASM_ROOT:-/opt/basm-local}"
  PRIMARY_DOMAIN=localhost
  if [[ "$BIND_ADDRESS" != 127.0.0.1 ]]; then PRIMARY_DOMAIN=basm.test; fi
  ERP_URL="erp.$PRIMARY_DOMAIN"
  MAIL_URL="mail.$PRIMARY_DOMAIN"
  CLOUD_URL="cloud.$PRIMARY_DOMAIN"
  BACKUP_LOCATION="$BASM_ROOT/backups"
  export DEPLOYMENT_MODE BIND_ADDRESS BASM_ROOT PRIMARY_DOMAIN ERP_URL MAIL_URL CLOUD_URL BACKUP_LOCATION
}

render_stack() {
  local proxy_template="$ROOT_DIR/templates/traefik.yml"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    proxy_template="$ROOT_DIR/templates/traefik-local.yml"
  fi
  export BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
  export BASM_CONTAINER_PREFIX="${BASM_CONTAINER_PREFIX:-basm}"
  ensure_port_defaults
  envsubst < "$ROOT_DIR/templates/docker-compose.yml" > "$BASM_ROOT/docker-compose.yml"
  envsubst < "$proxy_template" > "$BASM_ROOT/config/traefik.yml"
  envsubst < "$ROOT_DIR/templates/traefik-static.yml" > "$BASM_ROOT/config/traefik-static.yml"
  if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
    cat >> "$BASM_ROOT/config/traefik-static.yml" <<EOF
certificatesResolvers:
  letsencrypt:
    acme:
      email: "$ADMIN_EMAIL"
      storage: "/data/acme.json"
      tlsChallenge: {}
EOF
  fi
}

prompt_value() {
  local label="$1"
  local default_value="$2"
  local validator="${3:-}"
  local value=""

  while true; do
    if [[ -n "$default_value" ]]; then
      read -rp "$label [$default_value]: " value
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

select_deployment() {
  local domain
  domain="$(prompt_value "Primary domain (e.g. example.com), or 'local' for local test setup" example.com '[[ "$1" == local || "$1" == localhost || "$1" == 127.0.0.1 ]] || validate_domain "$1"')"
  LOCAL_MODE=false
  BASM_ENV_FILE="$CONFIG_DIR/basm.env"
  BASM_ROOT="${PRODUCTION_BASM_ROOT:-/opt/basm}"
  if [[ "$domain" == local || "$domain" == localhost || "$domain" == 127.0.0.1 ]]; then
    LOCAL_MODE=true
    BASM_ENV_FILE="$CONFIG_DIR/local.env"
    BASM_ROOT="${LOCAL_BASM_ROOT:-/opt/basm-local}"
  fi
  if [[ -f "$BASM_ENV_FILE" ]]; then
    set -a
    source "$BASM_ENV_FILE"
    set +a
  fi
  if [[ "$LOCAL_MODE" == false ]]; then
    if [[ "${PRIMARY_DOMAIN:-}" != "$domain" ]]; then
      unset ERP_URL MAIL_URL CLOUD_URL
    fi
    PRIMARY_DOMAIN="$domain"
  fi
}

print_module_menu() {
  printf '\nBASM installation menu\n\n'
  printf '[✓] BASM Core (required)\n'
  printf '[ ] LAMP\n'
  printf '[ ] WireGuard\n'
  printf '[ ] Fluxer\n'
  printf '[ ] Vaultwarden\n'
  printf '[ ] Uptime Kuma\n\n'
  printf 'Select modules by number (1-6), separated by spaces. Leave blank to use defaults.\n'
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
  )

  print_module_menu
  read -rp "Module selection: " input

  if [[ -z "$input" ]]; then
    BASM_MODULES="basm"
    return
  fi

  local choice
  for choice in $input; do
    if [[ "$choice" =~ ^[1-6]$ ]]; then
      if [[ ! " ${selected[*]} " =~ " ${map[$choice]} " ]]; then
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

run_wizard() {
  log "Launching BASM wizard"

  select_deployment

  if [[ "${LOCAL_MODE:-false}" == true ]]; then
    LOCAL_BIND_ADDRESS="$(prompt_value "Local bind address (localhost or private LAN IPv4)" localhost '[[ "$1" == localhost ]] || validate_local_bind_address "$1"')"
    if [[ "$LOCAL_BIND_ADDRESS" == localhost ]]; then LOCAL_BIND_ADDRESS=127.0.0.1; fi
    configure_local_mode
    BASM_CONTAINER_PREFIX=basm-local
  else
    DEPLOYMENT_MODE=production
    BIND_ADDRESS=0.0.0.0
    BASM_CONTAINER_PREFIX=basm
  fi

  COMPANY_NAME="$(prompt_value "Company Name" "${COMPANY_NAME:-BASM Business}" "[[ \"\$1\" != \"\" ]]")"
  ADMIN_EMAIL="$(prompt_value "Administrator Email" "${ADMIN_EMAIL:-admin@example.com}" "validate_email \"\$1\"")"
  TIMEZONE="$(prompt_value "Timezone" "${TIMEZONE:-Etc/UTC}" "[[ \"\$1\" != \"\" ]]")"

  SSH_PORT="${SSH_PORT:-22}"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then
    ERP_URL="$(prompt_value "ERP URL" "${ERP_URL:-erp.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"
    MAIL_URL="$(prompt_value "Mail URL" "${MAIL_URL:-mail.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"
    CLOUD_URL="$(prompt_value "Cloud URL" "${CLOUD_URL:-cloud.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"
    BACKUP_LOCATION="${BACKUP_LOCATION:-/var/backups/basm}"
  fi

  select_modules
  configure_ports

  cat > "$BASM_ENV_FILE" <<EOF
DEPLOYMENT_MODE="$DEPLOYMENT_MODE"
BIND_ADDRESS="$BIND_ADDRESS"
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
ERP_URL="$ERP_URL"
MAIL_URL="$MAIL_URL"
CLOUD_URL="$CLOUD_URL"
BACKUP_LOCATION="$BACKUP_LOCATION"
BASM_ROOT="$BASM_ROOT"
BASM_MODULES="$BASM_MODULES"
EOF

  source "$BASM_ENV_FILE"
  export DEPLOYMENT_MODE BIND_ADDRESS BASM_CONTAINER_PREFIX COMPANY_NAME PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE HTTP_PORT HTTPS_PORT SSH_PORT ERP_URL MAIL_URL CLOUD_URL BACKUP_LOCATION BASM_ROOT BASM_MODULES
}

configure_system() {
  log "Configuring Debian installation"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release gettext-base tzdata net-tools iproute2 openssl

  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  ensure_dir "$BASM_ROOT"
  ensure_dir "$BASM_ROOT/config"
  ensure_dir "$BASM_ROOT/data"
  ensure_dir "$BASM_ROOT/logs"
  ensure_dir "$BACKUP_LOCATION"
  ensure_dir "$OUTPUT_DIR"

  render_stack

  log "System setup complete"
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
}

run_module_install() {
  local module_name="$1"
  local script_path="$MODULES_DIR/${module_name}.sh"

  ensure_port_defaults
  (BASM_MODULES="${BASM_MODULES:-basm} $module_name"; validate_port_plan) || fail "Resolve port conflicts in the setup wizard before installing this module."

  if [[ ! -f "$script_path" ]]; then
    fail "Module '$module_name' was requested but no installer script exists at $script_path"
  fi

  log "Running module installer: $module_name"
  source "$script_path"
  if declare -F module_install >/dev/null; then
    module_install
  else
    fail "Module '$module_name' does not expose a module_install function."
  fi
}

port_summary() {
  printf 'Port Profile: %s\n' "${PORT_PROFILE:-custom}"
  printf 'Proxy HTTP: %s/tcp\nProxy HTTPS: %s/tcp\n' "$HTTP_PORT" "$HTTPS_PORT"
  printf 'Host SSH (unchanged): %s/tcp\n' "${SSH_PORT:-22}"
  local module_name
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) printf 'LAMP: http://%s:%s\n' "$BIND_ADDRESS" "$LAMP_PORT" ;;
      uptime-kuma) printf 'Uptime Kuma: http://%s:%s\n' "$BIND_ADDRESS" "$UPTIME_KUMA_PORT" ;;
      wireguard) printf 'WireGuard generated ListenPort: %s/udp\n' "$WIREGUARD_PORT" ;;
    esac
  done
}

write_summary() {
  local summary_file="$OUTPUT_DIR/installation-summary.txt"
  local modules_list="${BASM_MODULES:-basm}"

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
- Cloud: http://$BIND_ADDRESS:$HTTP_PORT
- Cloud: http://$CLOUD_URL:$HTTP_PORT
- ERP: http://$ERP_URL:$HTTP_PORT
- Mail: http://$MAIL_URL:$HTTP_PORT

For LAN clients, map $ERP_URL, $MAIL_URL and $CLOUD_URL
to $BIND_ADDRESS in each client's hosts file or private DNS.
Do not forward these ports on your router. HTTP is unencrypted.
SSH settings and the host firewall are not changed by local mode.
Existing upstream ERPNext/Postal provisioning steps still apply.
Optional modules retain their existing generation-only behavior.
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
- ERP: https://$ERP_URL:$HTTPS_PORT
- Mail: https://$MAIL_URL:$HTTPS_PORT
- Cloud: https://$CLOUD_URL:$HTTPS_PORT

Ports:
$(port_summary)

Backup Location:
- $BACKUP_LOCATION

DNS Records Required:
- A record for $PRIMARY_DOMAIN -> Public IP
- A record for $ERP_URL -> Public IP
- A record for $MAIL_URL -> Public IP
- A record for $CLOUD_URL -> Public IP

Router Port Forwarding Required:
- Forward $HTTP_PORT to the BASM server
- Forward $HTTPS_PORT to the BASM server
- Forward $SSH_PORT only if administrative access is required externally

Post-installation Checklist:
[ ] Point DNS A record to public IP
[ ] Forward ports $HTTP_PORT and $HTTPS_PORT on the router
[ ] Test outgoing mail
[ ] Store admin credentials securely
[ ] Verify backup completion

Generated at: $(date -u +'%Y-%m-%d %H:%M:%S UTC')
EOF

  log "Summary written to $summary_file"
}
