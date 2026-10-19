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
  if command -v ss >/dev/null 2>&1; then
    ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" && return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$" && return 0
  fi

  return 1
}

validate_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

validate_domain() {
  [[ "$1" =~ ^([a-zA-Z0-9.-]+\.)+[a-zA-Z]{2,}$ ]]
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

    if [[ -n "$validator" ]] && ! eval "$validator \"\$value\""; then
      warn "Invalid value for $label. Please try again."
      continue
    fi

    printf '%s\n' "$value"
    return 0
  done
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

  if [[ -f "$CONFIG_DIR/basm.env" ]]; then
    source "$CONFIG_DIR/basm.env"
  fi

  COMPANY_NAME="$(prompt_value "Company Name" "${COMPANY_NAME:-BASM Business}" "[[ \"\$1\" != \"\" ]]")"
  PRIMARY_DOMAIN="$(prompt_value "Primary Domain" "${PRIMARY_DOMAIN:-example.com}" "validate_domain \"\$1\"")"
  ADMIN_EMAIL="$(prompt_value "Administrator Email" "${ADMIN_EMAIL:-admin@example.com}" "validate_email \"\$1\"")"
  TIMEZONE="$(prompt_value "Timezone" "${TIMEZONE:-Etc/UTC}" "[[ \"\$1\" != \"\" ]]")"

  HTTP_PORT="$(prompt_value "HTTP Port" "${HTTP_PORT:-80}" "[[ \"\$1\" =~ ^[0-9]+$ ]] && [[ \"\$1\" -ge 1 && \"\$1\" -le 65535 ]]" )"
  if port_in_use "$HTTP_PORT"; then warn "Port $HTTP_PORT is already in use on this host."; fi

  HTTPS_PORT="$(prompt_value "HTTPS Port" "${HTTPS_PORT:-443}" "[[ \"\$1\" =~ ^[0-9]+$ ]] && [[ \"\$1\" -ge 1 && \"\$1\" -le 65535 ]]" )"
  if port_in_use "$HTTPS_PORT"; then warn "Port $HTTPS_PORT is already in use on this host."; fi

  SSH_PORT="$(prompt_value "SSH Port" "${SSH_PORT:-22}" "[[ \"\$1\" =~ ^[0-9]+$ ]] && [[ \"\$1\" -ge 1 && \"\$1\" -le 65535 ]]" )"
  if port_in_use "$SSH_PORT"; then warn "Port $SSH_PORT is already in use on this host."; fi

  ERP_URL="$(prompt_value "ERP URL" "${ERP_URL:-erp.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"
  MAIL_URL="$(prompt_value "Mail URL" "${MAIL_URL:-mail.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"
  CLOUD_URL="$(prompt_value "Cloud URL" "${CLOUD_URL:-cloud.$PRIMARY_DOMAIN}" "[[ \"\$1\" != \"\" ]]")"

  select_modules

  cat > "$CONFIG_DIR/basm.env" <<EOF
COMPANY_NAME="$COMPANY_NAME"
PRIMARY_DOMAIN="$PRIMARY_DOMAIN"
ADMIN_EMAIL="$ADMIN_EMAIL"
TIMEZONE="$TIMEZONE"
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
SSH_PORT=$SSH_PORT
ERP_URL="$ERP_URL"
MAIL_URL="$MAIL_URL"
CLOUD_URL="$CLOUD_URL"
BACKUP_LOCATION="/var/backups/basm"
BASM_ROOT="$BASM_ROOT"
BASM_MODULES="$BASM_MODULES"
EOF

  source "$CONFIG_DIR/basm.env"
  export COMPANY_NAME PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE HTTP_PORT HTTPS_PORT SSH_PORT ERP_URL MAIL_URL CLOUD_URL BACKUP_LOCATION BASM_ROOT BASM_MODULES
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

  if [[ -f "$ROOT_DIR/templates/docker-compose.yml" ]]; then
    envsubst < "$ROOT_DIR/templates/docker-compose.yml" > "$BASM_ROOT/docker-compose.yml"
  fi

  if [[ -f "$ROOT_DIR/templates/traefik.yml" ]]; then
    envsubst < "$ROOT_DIR/templates/traefik.yml" > "$BASM_ROOT/config/traefik.yml"
  fi

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

write_summary() {
  local summary_file="$OUTPUT_DIR/installation-summary.txt"
  local modules_list="${BASM_MODULES:-basm}"

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
- ERP: https://$ERP_URL
- Mail: https://$MAIL_URL
- Cloud: https://$CLOUD_URL

Open Ports:
- HTTP: $HTTP_PORT
- HTTPS: $HTTPS_PORT
- SSH: $SSH_PORT

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
