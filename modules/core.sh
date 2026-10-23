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
BASM_REQUIRED_PACKAGES="ca-certificates curl gnupg lsb-release gettext-base tzdata net-tools iproute2 openssl"

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

validate_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
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
  for module_name in basm lamp wireguard fluxer vaultwarden uptime-kuma; do
    case "$module_name" in
      basm) label='BASM Core (required)' ;;
      lamp) label='LAMP' ;;
      wireguard) label='WireGuard' ;;
      fluxer) label='Fluxer' ;;
      vaultwarden) label='Vaultwarden' ;;
      uptime-kuma) label='Uptime Kuma' ;;
    esac
    mark=' '
    if [[ "$module_name" == basm ]] || module_selected "$module_name"; then mark='✓'; fi
    printf '%s) [%s] %s\n' "$index" "$mark" "$label"
    index=$((index + 1))
  done
  printf '\nSelect modules by number (1-6), separated by spaces, or enter "full" for\n'
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
  fi

  select_modules
  configure_ports
  if port_in_use "$SMTP_PORT"; then
    warn "Postal SMTP port $SMTP_PORT/tcp is already in use. Choose an available port or stop its current owner."
  fi

  DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-$(generate_secret)}"
  ERP_ADMIN_PASSWORD="${ERP_ADMIN_PASSWORD:-$(generate_secret)}"
  NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-basm-admin}"
  NEXTCLOUD_ADMIN_PASSWORD="${NEXTCLOUD_ADMIN_PASSWORD:-$(generate_secret)}"
  POSTAL_DB_PASSWORD="${POSTAL_DB_PASSWORD:-$(generate_secret)}"
  POSTAL_ADMIN_PASSWORD="${POSTAL_ADMIN_PASSWORD:-$(generate_secret)}"
  POSTAL_RAILS_SECRET="${POSTAL_RAILS_SECRET:-$(generate_secret)}"
  NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-$(generate_secret)}"
  POSTAL_WEB_PROTOCOL=http
  if [[ "$DEPLOYMENT_MODE" != local ]]; then POSTAL_WEB_PROTOCOL=https; fi
  RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(generate_secret)}"

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

Initial login details:
- ERPNext user: Administrator
- Nextcloud user: $NEXTCLOUD_ADMIN_USER
- Postal user: $ADMIN_EMAIL
- Generated passwords and database secrets: $BASM_ROOT/config/basm.env (root-only)

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
- ERPNext user: Administrator
- Nextcloud user: $NEXTCLOUD_ADMIN_USER
- Postal user: $ADMIN_EMAIL
- Generated passwords and database secrets: $BASM_ROOT/config/basm.env (root-only)

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
- Forward $HTTP_PORT to the BASM server
- Forward $HTTPS_PORT to the BASM server
- Forward $SSH_PORT only if administrative access is required externally

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
