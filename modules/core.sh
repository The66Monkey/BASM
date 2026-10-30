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

BASM_FULL_MODULES="basm lamp wireguard uptime-kuma"
BASM_REQUIRED_PACKAGES="ca-certificates curl gnupg lsb-release gettext-base tzdata net-tools iproute2 openssl cron util-linux"

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
  local root="${1:-$BASM_ROOT}" file
  for file in "$root"/modules/*/docker-compose.yml; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
  return 0
}

start_module_stack() {
  local compose_file="$BASM_ROOT/modules/$1/docker-compose.yml"
  command -v docker >/dev/null 2>&1 || fail "Docker CLI was not found; module '$1' cannot be started."
  log "Starting $1 module"
  basm_compose -f "$compose_file" up -d --remove-orphans --quiet-pull || fail "Module '$1' did not start cleanly."
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
    "$POSTAL_ADMIN_PASSWORD" "$DB_ROOT_PASSWORD" "$NEXTCLOUD_DB_PASSWORD" "$POSTAL_DB_PASSWORD" \
    "$POSTAL_RAILS_SECRET" "$RESTIC_PASSWORD" "$BACKUP_LOCATION" "${DESEC_TOKEN:-}" "${BASM_MODULES:-basm}" \
    "$PRIMARY_DOMAIN" "$UPTIME_KUMA_PORT" | /usr/bin/python3 "$ROOT_DIR/templates/keepass-sync.py" "$BASM_ROOT"
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
  local default_http=80 default_https=443 default_lamp=8080 default_kuma=3001 default_wireguard=51820
  local default_smtp=25
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    default_http=18080 default_https=18443 default_lamp=18081 default_kuma=18301 default_wireguard=18520
    default_smtp=2525
  fi
  HTTP_PORT="${HTTP_PORT:-$default_http}"
  HTTPS_PORT="${HTTPS_PORT:-$default_https}"
  LAMP_PORT="${LAMP_PORT:-$default_lamp}"
  UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-$default_kuma}"
  WIREGUARD_PORT="${WIREGUARD_PORT:-$default_wireguard}"
  SMTP_PORT="${SMTP_PORT:-$default_smtp}"
  SSH_PORT="${SSH_PORT:-22}"
  export HTTP_PORT HTTPS_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT SSH_PORT SMTP_PORT
}

set_port_defaults() {
  HTTP_PORT=80
  HTTPS_PORT=443
  LAMP_PORT=8080
  UPTIME_KUMA_PORT=3001
  WIREGUARD_PORT=51820
  SMTP_PORT=25
  if [[ "$1" == local ]]; then
    HTTP_PORT=18080
    HTTPS_PORT=18443
    LAMP_PORT=18081
    UPTIME_KUMA_PORT=18301
    WIREGUARD_PORT=18520
    SMTP_PORT=2525
  fi
}

validate_port_plan() {
  local -A assigned=(["${SSH_PORT:-22}"]="host SSH")
  local variable module_name port
  local -a tcp_ports=(HTTP_PORT HTTPS_PORT SMTP_PORT)
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
  local -a custom_ports=(HTTP_PORT HTTPS_PORT SMTP_PORT)
  ensure_port_defaults
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then default_profile=local; fi
  for module_name in ${BASM_MODULES:-basm} $BASM_FULL_MODULES; do
    case "$module_name" in
      lamp) variable=LAMP_PORT ;;
      uptime-kuma) variable=UPTIME_KUMA_PORT ;;
      wireguard) variable=WIREGUARD_PORT ;;
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
    if (BASM_MODULES="${BASM_MODULES:-basm} $BASM_FULL_MODULES"; validate_port_plan); then break; fi
    warn "Choose a port profile again to resolve the conflict."
  done
  for variable in "${custom_ports[@]}"; do
    protocol=tcp
    if [[ "$variable" == WIREGUARD_PORT ]]; then protocol=udp; fi
    if port_in_use "${!variable}" "$protocol"; then
      warn "$variable (${!variable}/$protocol) is already in use on this host. Stop its current owner or rerun with custom ports."
    fi
  done
  export PORT_PROFILE HTTP_PORT HTTPS_PORT SMTP_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT
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
  local compose_variables='${BASM_ROOT} ${BIND_ADDRESS} ${HTTP_PORT} ${HTTPS_PORT} ${BASM_CONTAINER_PREFIX} ${SMTP_BIND_ADDRESS} ${SMTP_PORT} ${BACKUP_LOCATION} ${NEXTCLOUD_TRUSTED_DOMAINS}'
  export BIND_ADDRESS="${BIND_ADDRESS:-0.0.0.0}"
  export NEXTCLOUD_TRUSTED_DOMAINS="${CLOUD_URL:-}"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    proxy_template="$ROOT_DIR/templates/traefik-local.yml"
    NEXTCLOUD_TRUSTED_DOMAINS="$CLOUD_URL localhost 127.0.0.1"
    if [[ "$BIND_ADDRESS" != 127.0.0.1 ]]; then NEXTCLOUD_TRUSTED_DOMAINS+=" $BIND_ADDRESS"; fi
  fi
  export BASM_CONTAINER_PREFIX="${BASM_CONTAINER_PREFIX:-basm}"
  ensure_port_defaults
  envsubst "$compose_variables" < "$ROOT_DIR/templates/docker-compose.yml" > "$BASM_ROOT/docker-compose.yml"
  envsubst '${ERP_URL} ${MAIL_URL} ${CLOUD_URL} ${BIND_ADDRESS} ${HTTPS_PORT}' < "$proxy_template" > "$BASM_ROOT/config/traefik.yml"
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

render_postal_config() {
  local postal_config_dir="$BASM_ROOT/config/postal"
  ensure_dir "$postal_config_dir"
  envsubst '${MAIL_URL} ${POSTAL_WEB_PROTOCOL} ${PRIMARY_DOMAIN} ${ADMIN_EMAIL} ${COMPANY_NAME} ${POSTAL_DB_PASSWORD} ${POSTAL_RAILS_SECRET}' \
    < "$ROOT_DIR/templates/postal.yml" > "$postal_config_dir/postal.yml"
  chmod 640 "$postal_config_dir/postal.yml"
  if [[ ! -f "$postal_config_dir/signing.key" ]]; then
    openssl genrsa -out "$postal_config_dir/signing.key" 2048
  fi
  chmod 640 "$postal_config_dir/signing.key"
  if [[ "$EUID" -eq 0 ]]; then
    chown 999:999 "$postal_config_dir/postal.yml" "$postal_config_dir/signing.key"
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
  local index=1 module_name label mark
  printf '\nBASM installation menu\n\n'
  for module_name in basm lamp wireguard fluxer vaultwarden uptime-kuma keepass; do
    case "$module_name" in
      basm) label='BASM Core (required)' ;;
      lamp) label='LAMP' ;;
      wireguard) label='WireGuard' ;;
      fluxer) label='Fluxer' ;;
      vaultwarden) label='Vaultwarden' ;;
      uptime-kuma) label='Uptime Kuma' ;;
      keepass) label='KeePassXC credential manager' ;;
    esac
    mark=' '
    if [[ "$module_name" == basm ]] || module_selected "$module_name"; then mark='✓'; fi
    printf '%s) [%s] %s\n' "$index" "$mark" "$label"
    index=$((index + 1))
  done
  printf '\nSelect modules by number (1-7), separated by spaces, or enter "full" for\n'
  printf 'Core + LAMP + WireGuard + Uptime Kuma. Leave blank to keep the checked modules.\n'
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
    if [[ "$choice" =~ ^[1-7]$ ]]; then
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

write_env_file() {
  mkdir -p "$(dirname "$BASM_ENV_FILE")"
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
IP_MODE="${IP_MODE:-static}"
DESEC_TOKEN="${DESEC_TOKEN:-}"
BACKUP_LOCATION="$BACKUP_LOCATION"
BASM_ROOT="$BASM_ROOT"
BASM_MODULES="$BASM_MODULES"
DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD"
ERP_ADMIN_PASSWORD="$ERP_ADMIN_PASSWORD"
NEXTCLOUD_ADMIN_USER="$NEXTCLOUD_ADMIN_USER"
NEXTCLOUD_ADMIN_PASSWORD="$NEXTCLOUD_ADMIN_PASSWORD"
POSTAL_DB_PASSWORD="$POSTAL_DB_PASSWORD"
POSTAL_ADMIN_PASSWORD="$POSTAL_ADMIN_PASSWORD"
POSTAL_RAILS_SECRET="$POSTAL_RAILS_SECRET"
POSTAL_WEB_PROTOCOL="$POSTAL_WEB_PROTOCOL"
NEXTCLOUD_DB_PASSWORD="$NEXTCLOUD_DB_PASSWORD"
SMTP_BIND_ADDRESS="$SMTP_BIND_ADDRESS"
SMTP_PORT=$SMTP_PORT
RESTIC_PASSWORD="$RESTIC_PASSWORD"
EOF
  chmod 600 "$BASM_ENV_FILE"
}

run_wizard() {
  log "Launching BASM wizard"

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

  COMPANY_NAME="$(prompt_value "Company Name" "${COMPANY_NAME:-BASM Business}" 'validate_company_name "$1"')"
  local email_validator='validate_email "$1"' default_email="${ADMIN_EMAIL:-admin@example.com}"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then
    email_validator='validate_production_email "$1"'
    validate_production_email "$default_email" || default_email=""
  fi
  local attempt
  ADMIN_EMAIL=""
  for attempt in 1 2 3; do
    ADMIN_EMAIL="$(prompt_value "Administrator Email (Let's Encrypt and Postal admin)" "$default_email" "$email_validator")"
    [[ -n "$ADMIN_EMAIL" ]] && break
    warn "A real administrator email address is required for production certificates."
  done
  [[ -n "$ADMIN_EMAIL" ]] || fail "No valid administrator email address was provided."
  TIMEZONE="$(prompt_value "Timezone" "${TIMEZONE:-Etc/UTC}" 'validate_timezone "$1"')"
  NEXTCLOUD_ADMIN_USER="$(prompt_value "Nextcloud administrator username" "${NEXTCLOUD_ADMIN_USER:-basm-admin}" 'validate_admin_username "$1"')"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then BACKUP_LOCATION="${BACKUP_LOCATION:-/var/backups/basm}"; fi
  BACKUP_LOCATION="$(prompt_value "Backup destination directory" "${BACKUP_LOCATION:-$BASM_ROOT/backups}" 'validate_backup_path "$1"')"

  SSH_PORT="${SSH_PORT:-22}"
  if [[ "$DEPLOYMENT_MODE" != local ]]; then
    ERP_URL="$(prompt_value "ERP URL" "${ERP_URL:-erp.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    MAIL_URL="$(prompt_value "Mail URL" "${MAIL_URL:-mail.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    CLOUD_URL="$(prompt_value "Cloud URL" "${CLOUD_URL:-cloud.$PRIMARY_DOMAIN}" 'validate_domain "$1"')"
    IP_MODE="$(prompt_value "Public IP type: static, or non-static (keeps deSEC DNS updated)" "${IP_MODE:-static}" '[[ "$1" == static || "$1" == non-static ]]')"
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

  select_modules
  configure_ports
  if port_in_use "$SMTP_PORT"; then
    warn "Postal SMTP port $SMTP_PORT/tcp is already in use. Choose an available port or stop its current owner."
  fi

  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(generate_password)}"
  ERP_ADMIN_PASSWORD="${ERP_ADMIN_PASSWORD:-$(generate_password)}"
  NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-basm-admin}"
  NEXTCLOUD_ADMIN_PASSWORD="${NEXTCLOUD_ADMIN_PASSWORD:-$(generate_password)}"
  POSTAL_DB_PASSWORD="${POSTAL_DB_PASSWORD:-$(generate_password)}"
  POSTAL_ADMIN_PASSWORD="${POSTAL_ADMIN_PASSWORD:-$(generate_password)}"
  POSTAL_RAILS_SECRET="${POSTAL_RAILS_SECRET:-$(generate_secret)}"
  NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-$(generate_password)}"
  POSTAL_WEB_PROTOCOL=http
  if [[ "$DEPLOYMENT_MODE" != local ]]; then POSTAL_WEB_PROTOCOL=https; fi
  RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(generate_password)}"

  write_env_file

  source "$BASM_ENV_FILE"
  export DEPLOYMENT_MODE BIND_ADDRESS BASM_CONTAINER_PREFIX COMPANY_NAME PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE HTTP_PORT HTTPS_PORT SSH_PORT ERP_URL MAIL_URL CLOUD_URL BACKUP_LOCATION BASM_ROOT BASM_MODULES DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD POSTAL_DB_PASSWORD POSTAL_ADMIN_PASSWORD POSTAL_RAILS_SECRET POSTAL_WEB_PROTOCOL SMTP_BIND_ADDRESS SMTP_PORT RESTIC_PASSWORD
}

configure_system() {
  log "Configuring Debian installation"

  if [[ "${DEPLOYMENT_MODE:-production}" != local ]]; then
    local host memory_kib
    for host in "$ERP_URL" "$MAIL_URL" "$CLOUD_URL"; do
      if ! getent ahostsv4 "$host" >/dev/null 2>&1; then
        warn "DNS for $host does not resolve yet; public routes and TLS issuance will not be ready."
      fi
    done
    memory_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    if (( memory_kib < 4194304 )) || (( $(nproc) < 2 )); then
      warn "Postal recommends at least 4 GiB RAM and 2 CPU cores; this host is below that baseline."
    fi
    warn "Production mail requires public MX/SPF/DKIM/DMARC records and inbound/outbound TCP port 25."
  fi

  # shellcheck disable=SC2086
  ensure_packages $BASM_REQUIRED_PACKAGES

  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release; echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    fi
    ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  ensure_dir "$BASM_ROOT"
  ensure_dir "$BASM_ROOT/config"
  ensure_dir "$BASM_ROOT/data"
  ensure_dir "$BASM_ROOT/data/db-backups"
  chmod 700 "$BASM_ROOT/data/db-backups"
  ensure_dir "$BASM_ROOT/logs"
  ensure_dir "$BACKUP_LOCATION"
  ensure_dir "$BACKUP_LOCATION/restic"
  ensure_dir "$OUTPUT_DIR"
  cp "$ROOT_DIR/templates/erpnext-create-site.sh" "$BASM_ROOT/config/erpnext-create-site.sh"
  chmod 755 "$BASM_ROOT/config/erpnext-create-site.sh"

  render_stack
  render_postal_config
  prepare_full_profile

  log "System setup complete"
}

prepare_full_profile() {
  local module_name
  for module_name in $BASM_FULL_MODULES; do
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
}

update_cron_file() {
  local identifier
  identifier="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  printf '%s/basm-%s' "${BASM_CRON_DIR:-/etc/cron.d}" "$identifier"
}

install_auto_updates() (
  umask 077
  local maintenance_dir="$BASM_ROOT/maintenance" cron_file
  ensure_packages cron util-linux
  validate_backup_path "$BASM_ROOT" || fail "Deployment path is not safe for cron."
  [[ "$BASM_ROOT" != *%* ]] || fail "Deployment path cannot contain a percent sign."
  cron_file="$(update_cron_file "$BASM_ROOT")"
  install -d -m 700 "$maintenance_dir" "$maintenance_dir/modules" "$BASM_ROOT/logs" || fail "Cannot create maintenance directories."
  install -m 700 "$ROOT_DIR/update.sh" "$maintenance_dir/update.sh" || fail "Cannot install updater."
  install -m 600 "$ROOT_DIR/modules/core.sh" "$maintenance_dir/modules/core.sh" || fail "Cannot install updater helpers."
  cat > "$maintenance_dir/run-updates.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [[ -e "$BASM_ROOT/config/disable-auto-updates" ]]; then exit 0; fi
exec >> "$BASM_ROOT/logs/automatic-updates.log" 2>&1
printf '\\nScheduled BASM update started at %s\\n' "\$(date -Is)"
exec /bin/bash "$maintenance_dir/update.sh" --scheduled "$BASM_ROOT"
EOF
  chmod 700 "$maintenance_dir/run-updates.sh" || fail "Cannot protect update launcher."
  mkdir -p "$(dirname "$cron_file")" || fail "Cannot create cron directory."
  cat > "$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 1 1,7 * root /bin/bash "$maintenance_dir/run-updates.sh"
EOF
  chmod 644 "$cron_file" || fail "Cannot set cron permissions."
  systemctl enable --now cron || fail "Cannot enable the automatic update scheduler."
  log "Automatic application updates scheduled for January 1 and July 1 at 03:00 (server time)."
)

ddns_cron_file() {
  local identifier
  identifier="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  printf '%s/basm-ddns-%s' "${BASM_CRON_DIR:-/etc/cron.d}" "$identifier"
}

# Non-static IP installs check the public IPv4 every 4 hours and update deSEC.
install_ddns_updater() (
  umask 077
  local maintenance_dir="$BASM_ROOT/maintenance" cron_file
  cron_file="$(ddns_cron_file "$BASM_ROOT")"
  if [[ "${DEPLOYMENT_MODE:-production}" == local || "${IP_MODE:-static}" != non-static ]]; then
    rm -f "$cron_file" "$maintenance_dir/ddns-update.sh"
    return 0
  fi
  [[ "$BASM_ROOT" != *%* ]] || fail "Deployment path cannot contain a percent sign."
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
  log "deSEC DNS updates scheduled every 4 hours for the non-static public IP."
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
  unset -f module_install module_start
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

load_deployment_env() {
  [[ -f "$BASM_ENV_FILE" ]] || fail "No BASM configuration was found at $BASM_ENV_FILE. Run the full installer for this environment first."
  set -a
  source "$BASM_ENV_FILE"
  set +a
  if [[ "${LOCAL_MODE:-false}" == true ]]; then
    [[ "${DEPLOYMENT_MODE:-}" == local ]] || fail "Expected a local environment configuration."
    validate_local_bind_address "$BIND_ADDRESS" || fail "Unsafe local bind address."
  fi
  ensure_port_defaults
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
    lamp) printf 'LAMP_PORT' ;;
    uptime-kuma) printf 'UPTIME_KUMA_PORT' ;;
    wireguard) printf 'WIREGUARD_PORT' ;;
  esac
}

# Adds optional modules to an existing deployment without touching the core
# stack, system packages, or credentials. Already-cached images are reused.
upgrade_modules() {
  local module_name variable protocol
  local -a added=()
  [[ -f "$BASM_ROOT/docker-compose.yml" ]] || fail "No core BASM stack was found at $BASM_ROOT. Run the full installer first."
  for module_name in "$@"; do
    [[ -f "$MODULES_DIR/$module_name.sh" ]] || fail "Unknown module: $module_name"
    module_selected "$module_name" || added+=("$module_name")
  done
  add_modules_to_selection "$@"

  while ! validate_port_plan; do
    warn "The current port plan conflicts with the requested modules. Choose new module ports."
    for module_name in "${added[@]}"; do
      variable="$(module_port_variable "$module_name")"
      [[ -n "$variable" ]] || continue
      printf -v "$variable" '%s' "$(prompt_value "$variable" "${!variable}" 'validate_port "$1"')"
    done
    PORT_PROFILE=custom
  done
  for module_name in "${added[@]}"; do
    variable="$(module_port_variable "$module_name")"
    [[ -n "$variable" ]] || continue
    protocol=tcp
    if [[ "$variable" == WIREGUARD_PORT ]]; then protocol=udp; fi
    if port_in_use "${!variable}" "$protocol"; then
      warn "$variable (${!variable}/$protocol) is already in use on this host."
    fi
  done
  export PORT_PROFILE LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT

  write_env_file
  for module_name in "$@"; do
    [[ "$module_name" == basm ]] && continue
    run_module_install "$module_name" || fail "Module '$module_name' failed to install."
  done
  install_auto_updates
  install_ddns_updater
  write_summary
  log "Installed modules: $BASM_MODULES"
}

upgrade_to_full() {
  log "Upgrading $BASM_ROOT to the full BASM profile"
  # shellcheck disable=SC2086
  upgrade_modules $BASM_FULL_MODULES
}

# Stops a deployment's containers without removing data or volumes.
stop_deployment() {
  local root="$1" compose_file
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r compose_file; do
    basm_compose -f "$compose_file" down --remove-orphans || warn "Could not stop $compose_file"
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
    basm_compose -f "$root/docker-compose.yml" --env-file "$root/config/basm.env" up -d --remove-orphans || warn "Could not restart the core stack at $root"
  fi
  while IFS= read -r compose_file; do
    basm_compose -f "$compose_file" up -d --remove-orphans || warn "Could not restart $compose_file"
  done < <(module_compose_files "$root")
}

# Stops every BASM stack under a root, removes its containers, networks and
# named volumes, then deletes the directory. Docker images are kept so a later
# install can reuse them without downloading.
purge_deployment() {
  local root="$1" compose_file
  [[ -n "$root" && "$root" != / ]] || fail "Refusing to purge an empty or root path."
  rm -f "$(update_cron_file "$root")" "$(ddns_cron_file "$root")"
  if command -v docker >/dev/null 2>&1; then
    while IFS= read -r compose_file; do
      log "Stopping module stack $compose_file"
      basm_compose -f "$compose_file" down -v --remove-orphans || warn "Could not stop $compose_file"
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
  if [[ -f "$production_root/docker-compose.yml" ]]; then
    fail "A production stack already exists at $production_root. Use ./update.sh or uninstall it before promoting."
  fi
  set -a
  source "$local_root/config/basm.env"
  set +a
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
    LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT SMTP_PORT SMTP_BIND_ADDRESS ERP_URL MAIL_URL CLOUD_URL \
    BACKUP_LOCATION PRIMARY_DOMAIN DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD \
    NEXTCLOUD_DB_PASSWORD POSTAL_DB_PASSWORD POSTAL_ADMIN_PASSWORD POSTAL_RAILS_SECRET \
    POSTAL_WEB_PROTOCOL RESTIC_PASSWORD; do
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
  printf 'Postal SMTP: %s/tcp\n' "$SMTP_PORT"
  printf 'Host SSH (unchanged): %s/tcp\n' "${SSH_PORT:-22}"
  printf 'Reusable install settings: %s/config/basm.env (root-only)\n' "$BASM_ROOT"
  local module_name variable protocol host="$BIND_ADDRESS"
  if [[ "$host" == 0.0.0.0 ]]; then host="$PRIMARY_DOMAIN"; fi
  for module_name in ${BASM_MODULES:-basm}; do
    case "$module_name" in
      lamp) printf 'LAMP: http://%s:%s\n' "$host" "$LAMP_PORT" ;;
      uptime-kuma) printf 'Uptime Kuma: http://%s:%s\n' "$host" "$UPTIME_KUMA_PORT" ;;
      wireguard) printf 'WireGuard: %s/udp (server and peer1 configs in %s/modules/wireguard; not started)\n' "$WIREGUARD_PORT" "$BASM_ROOT" ;;
    esac
  done
  for module_name in $BASM_FULL_MODULES; do
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

# Writes copy-paste DNS records for a production install (Postal split-hostname layout).
write_dns_records() {
  local file="$1" d="$PRIMARY_DOMAIN"
  local erp_sub cloud_sub mail_sub
  erp_sub="$(dns_subname "$ERP_URL")"
  cloud_sub="$(dns_subname "$CLOUD_URL")"
  mail_sub="$(dns_subname "$MAIL_URL")"
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
  ${mail_sub:-@}    A      PUBLIC_IP   (Postal web UI and SMTP: $MAIL_URL)
  mx                A      PUBLIC_IP   (inbound mail host)
$(if [[ "${IP_MODE:-static}" == non-static ]]; then printf '  The A records above are kept current by the BASM DDNS job; do not edit them by hand.\n'; fi)
Postal server-wide records
  spf               TXT    "v=spf1 a:$MAIL_URL ~all"
  routes            MX     10 mx.$d.
  rp                MX     10 mx.$d.
  rp                TXT    "v=spf1 a mx include:spf.$d ~all"
  track             CNAME  $MAIL_URL.

Mail domain $d (sending and receiving through Postal)
  @                 MX     10 mx.$d.
  @                 TXT    "v=spf1 a mx include:spf.$d ~all"
  psrp              CNAME  rp.$d.
  _dmarc            TXT    "v=DMARC1; p=none; rua=mailto:postmaster@$d"

DKIM (only available after the domain is added in Postal)
  In Postal open the organization, Domains, then the DNS setup for $d.
  Copy the DKIM record it shows, which looks like:
  postal-XXXXXX._domainkey   TXT   "v=DKIM1; t=s; h=sha256; p=..."
  Add the same type of record for the return path domain (rp.$d) if Postal lists it.

If you also keep a separate fixed record elsewhere, note that only ONE SPF TXT
record may exist per name. Replace any older SPF record instead of adding a second.
Ask the ISP to set reverse DNS (PTR) of PUBLIC_IP to $MAIL_URL.

One-step setup for deSEC
------------------------
Paste the following into a terminal on any computer. It asks for a deSEC API
token (hidden), detects the public IPv4, and creates or updates the records
above, except DKIM. The token is not stored.

read -rsp 'deSEC API token: ' TOKEN; echo
PUBLIC_IP="\$(curl -4 -fsS https://api.ipify.org)"
BODY="\$(cat <<DNSJSON
[
 {"subname":"","type":"A","ttl":3600,"records":["\$PUBLIC_IP"]},
 {"subname":"$erp_sub","type":"A","ttl":3600,"records":["\$PUBLIC_IP"]},
 {"subname":"$cloud_sub","type":"A","ttl":3600,"records":["\$PUBLIC_IP"]},
 {"subname":"$mail_sub","type":"A","ttl":3600,"records":["\$PUBLIC_IP"]},
 {"subname":"mx","type":"A","ttl":3600,"records":["\$PUBLIC_IP"]},
 {"subname":"","type":"MX","ttl":3600,"records":["10 mx.$d."]},
 {"subname":"routes","type":"MX","ttl":3600,"records":["10 mx.$d."]},
 {"subname":"rp","type":"MX","ttl":3600,"records":["10 mx.$d."]},
 {"subname":"","type":"TXT","ttl":3600,"records":["\\"v=spf1 a mx include:spf.$d ~all\\""]},
 {"subname":"rp","type":"TXT","ttl":3600,"records":["\\"v=spf1 a mx include:spf.$d ~all\\""]},
 {"subname":"spf","type":"TXT","ttl":3600,"records":["\\"v=spf1 a:$MAIL_URL ~all\\""]},
 {"subname":"_dmarc","type":"TXT","ttl":3600,"records":["\\"v=DMARC1; p=none; rua=mailto:postmaster@$d\\""]},
 {"subname":"track","type":"CNAME","ttl":3600,"records":["$MAIL_URL."]},
 {"subname":"psrp","type":"CNAME","ttl":3600,"records":["rp.$d."]}
]
DNSJSON
)"
printf 'header = "Authorization: Token %s"\\n' "\$TOKEN" | curl -fsS -K - -X PATCH \\
  -H 'Content-Type: application/json' -d "\$BODY" \\
  "https://desec.io/api/v1/domains/$d/rrsets/" -o /dev/null -w 'HTTP %{http_code}\\n'
unset TOKEN

A result of HTTP 200 means the records were saved. DNS changes can take a few
minutes to appear. Verify with:
  dig +short MX $d
  dig +short TXT $d
  dig +short A $MAIL_URL
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

YOUR KEEPASS ACCESS
Open this database with KeePassXC (installed on the server), or another
KeePass-compatible application on your computer:
Database: $BASM_ROOT/config/credentials.kdbx
Master password: $keepass_master_password
No username is required. Ask IT to deliver the database file and this document.

The BASM group contains the service addresses, administrator logins, database
credentials, backup encryption password, and generated private keys.
Entries start with the installation values. Record password changes in KeePass;
installer reruns preserve existing entries rather than resetting your edits.
Ask IT to record any manually created monitoring, server, router, domain-provider,
internet-provider, and off-site backup accounts in the database too.
KeePass is a desktop application, not a web service, and opens no network port.

AUTOMATIC MAINTENANCE
BASM attempts application updates on January 1 and July 1 at 03:00 (server time).
Leave the server on. Services may briefly be unavailable. Ask IT to review
security updates, check backups, arrange an off-site copy, and test a restore.
Keep an independent copy of the database and master password for recovery;
the encrypted Restic backup cannot be opened without its password from KeePass.

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

YOUR SIGN-IN DETAILS
Open these addresses in your web browser. Passwords are case-sensitive.

Business accounts and operations (ERPNext)
Address: $scheme://$ERP_URL:$web_port
Username: Administrator
Initial password: $ERP_ADMIN_PASSWORD

Files and sharing (Nextcloud)
Address: $scheme://$CLOUD_URL:$web_port
Username: $NEXTCLOUD_ADMIN_USER
Initial password: $NEXTCLOUD_ADMIN_PASSWORD

Mail administration (Postal)
Address: $scheme://$MAIL_URL:$web_port
Username: $ADMIN_EMAIL
Initial password: $POSTAL_ADMIN_PASSWORD
Postal manages mail delivery; it is not an employee inbox or webmail service.
The email address above is a login name, not a newly created mailbox.

These are administrator accounts. Ask IT to create a personal account for each
employee; do not share these administrator passwords for everyday work.
Passwords shown here are the installation values. If changed in an application,
record the new value in your password manager. BASM cannot read it back, and
rerunning the installer does not reset it or update this document from the app.

OTHER ACCOUNTS
EOF
  if module_selected uptime-kuma; then
    cat >> "$handover_dir/for-the-user.txt" <<EOF
Monitoring (Uptime Kuma): http://$PRIMARY_DOMAIN:$UPTIME_KUMA_PORT
No account is generated. IT must complete first-time setup on the private
network and record the chosen username and password in your password manager.
EOF
  fi
  if module_selected lamp; then
    printf 'Website (LAMP): http://%s:%s - no login is created.\n' "$PRIMARY_DOMAIN" "$LAMP_PORT" >> "$handover_dir/for-the-user.txt"
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
Version-pinned applications still need IT review for newer releases.

BACKUPS AND RECOVERY (FOR YOUR IT HELPER)
Daily encrypted backups: $BACKUP_LOCATION/restic
Backup encryption password: $RESTIC_PASSWORD
No backup username is required for this local repository.
Keep an independent secure copy of this password, not only on this server.
Backups on the same server do not protect against theft or disk failure.
Ask IT to arrange an off-site copy and demonstrate a successful restore.

Technical database accounts, not browser logins:
ERPNext database server: erp-db; username: root; password: $DB_ROOT_PASSWORD
Nextcloud database server: nextcloud-db; username: root; password: $DB_ROOT_PASSWORD
Nextcloud application database: nextcloud; username: nextcloud; password: $NEXTCLOUD_DB_PASSWORD
Postal database server: postal-db; username: root; password: $POSTAL_DB_PASSWORD
Postal application signing secret (not a login): $POSTAL_RAILS_SECRET
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
  'KeePass is enabled: all service credentials are in config/credentials.kdbx.' \
  'The user document contains only KeePass access details. Record account changes' \
  'and manually created logins in KeePass. Deliver an independent recovery copy' \
  'of the database and master password before relying on encrypted backups.'; fi)

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
ERPNext: http://$ERP_URL:$HTTP_PORT
Postal: http://$MAIL_URL:$HTTP_PORT
With a localhost binding, use the browser on the server itself.
For LAN testing, rerun the wizard and select the server's private IPv4 as the
bind address. On each client, map these names to that address in private DNS
or its hosts file (Linux: /etc/hosts; Windows: C:\Windows\System32\drivers\etc\hosts):
  $BIND_ADDRESS $ERP_URL $MAIL_URL $CLOUD_URL
Use the selected private IPv4 instead of localhost in that entry.
HTTP is unencrypted: use test data and a trusted network only.
SMTP is loopback-only on $SMTP_PORT; public mail and HTTPS are not configured.
EOF
  else
    cat >> "$handover_dir/for-it.txt" <<EOF

3. CONNECT THE DOMAIN
In the router's Internet / WAN status, find the public IPv4. If it is private,
starts with 100.64.-100.127., or differs from your internet-facing public IP,
ask the ISP about carrier-grade NAT or an upstream router. Port forwarding
alone will not work through carrier-grade NAT. Request a public, preferably
static IPv4 and ask whether inbound AND outbound TCP 25 are allowed.
At the domain provider, create the DNS records in:
  $handover_dir/dns-records.txt
It lists the A, MX, SPF, DMARC and Postal records and, for deSEC, a paste-ready
command that creates them. The A records point to the public IPv4 for:
  $PRIMARY_DOMAIN
  $ERP_URL
  $MAIL_URL
  $CLOUD_URL
  mx.$PRIMARY_DOMAIN
Use DNS-only records, not a CDN proxy, during setup. Do not publish AAAA records
unless IPv6 routing and firewall rules have also been configured and tested.$(if [[ "${IP_MODE:-static}" == non-static ]]; then printf '\n%s' \
  "This install uses a non-static IP: every 4 hours cron updates these deSEC" \
  "records if the public IPv4 changed. Log: $BASM_ROOT/logs/ddns.log"; fi)

4. FORWARD THE ROUTER PORTS
Open NAT / Port Forwarding / Virtual Server. Add one rule per line below.
For every rule, destination is the reserved private server IPv4 from step 2.
Service        Protocol    External port    Internal (server) port
HTTP           TCP         $HTTP_PORT               $HTTP_PORT
HTTPS          TCP         $HTTPS_PORT              $HTTPS_PORT
Postal SMTP    TCP         25               $SMTP_PORT
If HTTP uses a custom port, ALSO forward external TCP 80 to internal $HTTP_PORT.
If HTTPS uses a custom port, ALSO forward external TCP 443 to internal $HTTPS_PORT.
These additional rules allow normal browser access, HTTPS redirects, and
Let's Encrypt HTTP certificate validation. Do not add a duplicate rule if the
selected port is already 80 or 443. Public mail requires external TCP 25.
Save/apply the rules. The URLs in the user document use the selected web ports;
the standard public ports also work with the additional rules above.
If the server firewall is enabled, permit these selected internal ports too.
Do not disable the firewall. Docker-published ports can bypass UFW rules;
verify reachability and filtering from outside the network.
Do not forward databases, Redis, Docker, monitoring, or router administration.
Do not forward SSH ($SSH_PORT) by default. Prefer a configured VPN for support.
LAMP and Uptime Kuma have no BASM-managed TLS or access control; keep their
ports private and restrict them on the host as well as at the router.

5. FINISH MAIL SETUP
Sign in to Postal using the user document. Configure your organization's mail
domains and sending servers, then publish the DKIM record Postal shows for the
domain; the other MX, SPF and DMARC records are in dns-records.txt (step 3).
An A record and port forwarding alone are not enough.
Ask the ISP to set reverse DNS (PTR) for the public IP to $MAIL_URL.
Configure application SMTP credentials in Postal; BASM does not generate them.
Postal is a mail delivery platform, not an IMAP/POP mailbox or webmail service.
Test sending AND receiving with an unrelated external mail provider. Do not
promise working mail until DNS, provider restrictions and delivery are checked.
EOF
  fi
  cat >> "$handover_dir/for-it.txt" <<EOF

6. CHECK BEFORE LEAVING
From the BASM checkout, inspect the services:
  sudo docker compose --env-file "$BASM_ROOT/config/basm.env" -f "$BASM_ROOT/docker-compose.yml" ps -a
  sudo docker compose --env-file "$BASM_ROOT/config/basm.env" -f "$BASM_ROOT/docker-compose.yml" logs --tail=100
One-shot initializer containers should exit successfully (code 0). Investigate
unhealthy containers, restart loops, and nonzero exits before handing over.
Open each service URL and actually sign in. In production, test public URLs
using mobile data with Wi-Fi off. Use https://$ERP_URL, https://$CLOUD_URL and
https://$MAIL_URL when external 443 maps to the selected server HTTPS port.
Do not dismiss certificate warnings. DNS or port changes can take time;
recheck DNS and Traefik logs if certificates are not issued.
If Uptime Kuma is selected, complete its first-run account setup privately.
WireGuard only generates files; it is NOT an active VPN. Follow the WireGuard
documentation to install/enable a server and create a separate peer per person.
Only after enabling it, forward UDP $WIREGUARD_PORT to the server's same port
for production use, and test the peer from outside. Never do this in local mode.

7. CHECK BACKUPS AND RECORD SUPPORT DETAILS
Read docs/backup.md in the BASM checkout for backup and restore commands.
Confirm a completed snapshot, arrange an encrypted off-site copy, and test a
restore to a separate location. Preserve the recovery password independently.
Do not restore over live business data during a test.
Record router, DNS provider, server administrator and off-site backup accounts
in the owner's password manager. BASM cannot supply their existing passwords.
Never attach the environment file or user document to a public support ticket.
Rerunning installation regenerates these handovers from saved BASM settings;
it does not discover changed application passwords or manually added accounts.
8. AUTOMATIC UPDATES
Installed updater: $BASM_ROOT/maintenance/update.sh
Schedule: January 1 and July 1 at 03:00, server time (cron; server must be on).
Cron file: $(update_cron_file "$BASM_ROOT")
Log: $BASM_ROOT/logs/automatic-updates.log
The scheduled run requires fresh database dumps and an encrypted Restic snapshot
before pulling images. It stops on errors and waits for running/healthy services.
There is no automatic rollback or external failure notification. Review the log
after each run and verify the owner can sign in. Missed runs are not caught up.
This only pulls configured image tags; it does not upgrade Debian, BASM source,
or version pins. Review pinned applications and apply urgent fixes separately.
To disable automatic runs persistently:
  sudo touch "$BASM_ROOT/config/disable-auto-updates"
To re-enable them:
  sudo rm "$BASM_ROOT/config/disable-auto-updates"
For quarterly runs, edit the cron month field from 1,7 to 1,4,7,10. Installer
reruns restore the six-month schedule but keep the disable file if present.
Manual updates: sudo ./update.sh (from the checkout, after confirming a usable
backup; manual runs do not create the scheduled pre-update snapshot).
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
    printf '%s\n' "- Service credentials: $BASM_ROOT/config/credentials.kdbx" \
      "- KeePass access: $BASM_ROOT/handover/for-the-user.txt (private)"
  else
    printf '%s\n' '- ERPNext user: Administrator' "- Nextcloud user: $NEXTCLOUD_ADMIN_USER" \
      "- Postal user: $ADMIN_EMAIL" "- All initial login details: $BASM_ROOT/handover/for-the-user.txt (private)"
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
- Cloud: http://$BIND_ADDRESS:$HTTP_PORT
- Cloud: http://$CLOUD_URL:$HTTP_PORT
- ERP: http://$ERP_URL:$HTTP_PORT
- Mail: http://$MAIL_URL:$HTTP_PORT

Initial login details:
$(credential_summary)

For LAN clients, map $ERP_URL, $MAIL_URL and $CLOUD_URL
to $BIND_ADDRESS in each client's hosts file or private DNS.
Do not forward these ports on your router. HTTP is unencrypted.
SSH settings and the host firewall are not changed by local mode.
Local mode initializes ERPNext, Nextcloud, and Postal's web UI. Postal SMTP binds only to loopback port $SMTP_PORT; public mail delivery requires a production domain and DNS records.
Restic encrypts daily backups to $BACKUP_LOCATION/restic.
LAMP and Uptime Kuma start automatically when selected; WireGuard generates configuration only.
Upgrade to the full profile: sudo ./install.sh --full (choose local)
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
- ERP: https://$ERP_URL:$HTTPS_PORT
- Mail: https://$MAIL_URL:$HTTPS_PORT
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
- A record for $CLOUD_URL -> Public IP
- MX, SPF, DKIM, and DMARC records for the mail domains shown in Postal

Router Port Forwarding Required:
- Forward TCP $HTTP_PORT and $HTTPS_PORT to the same server ports
- Also forward public TCP 80 -> $HTTP_PORT and TCP 443 -> $HTTPS_PORT if custom
- Forward public TCP 25 -> $SMTP_PORT for Postal mail delivery
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
