#!/usr/bin/env bash
# Exercises basic -> full upgrades and local -> production promotion with
# Docker, apt, and dpkg replaced by recording stubs. Needs no root or Docker.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/modules"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/modules/core.sh"

DOCKER_LOG="$TEST_DIR/docker.log"
APT_LOG="$TEST_DIR/apt.log"
: > "$DOCKER_LOG"
: > "$APT_LOG"
docker() { printf '%s\n' "$*" >> "$DOCKER_LOG"; }
apt-get() { printf '%s\n' "$*" >> "$APT_LOG"; }
dpkg-query() { printf 'install ok installed'; }
chown() { :; }
port_in_use() { return 1; }
check_debian() { :; }
export -f docker

LOCAL_BASM_ROOT="$TEST_DIR/basm-local"
PRODUCTION_BASM_ROOT="$TEST_DIR/basm"
OUTPUT_DIR="$TEST_DIR/output"
mkdir -p "$OUTPUT_DIR"

# Basic local install: blank module selection keeps core only.
run_wizard < <(printf 'local\n\nAcme Ltd\nops@acme.dk\n\n\n\n\ncustom\n19080\n19443\n12525\n19081\n51825\n19301\n')
[[ "$BASM_MODULES" == basm ]]
configure_system
install_selected_modules
write_summary
[[ ! -s "$APT_LOG" ]] || { cat "$APT_LOG" >&2; exit 1; }
grep -Fq "$LOCAL_BASM_ROOT/docker-compose.yml" "$DOCKER_LOG"
if grep -Eq '(^| )pull( |$)' "$DOCKER_LOG"; then exit 1; fi
LOCAL_DB_PASSWORD="$DB_ROOT_PASSWORD"
PREPARED_DIR="$LOCAL_BASM_ROOT/config/prepared-modules"
[[ ! -e "$LOCAL_BASM_ROOT/modules/lamp" && ! -e "$LOCAL_BASM_ROOT/modules/wireguard" && ! -e "$LOCAL_BASM_ROOT/modules/uptime-kuma" ]]
[[ -z "$(module_compose_files)" ]]
grep -Fq '"127.0.0.1:19081:80"' "$PREPARED_DIR/lamp/docker-compose.yml"
grep -Fq '"127.0.0.1:19301:3001"' "$PREPARED_DIR/uptime-kuma/docker-compose.yml"
grep -Fq 'ListenPort = 51825' "$PREPARED_DIR/wireguard/config.conf"
grep -Fq 'Endpoint = 127.0.0.1:51825' "$PREPARED_DIR/wireguard/peer1.conf"
[[ "$(stat -c '%a' "$PREPARED_DIR/wireguard/config.conf")" == 600 ]]
[[ "$(stat -c '%a' "$PREPARED_DIR/wireguard/peer1.conf")" == 600 ]]
grep -Fq 'Prepared lamp port (not active): 19081/tcp' "$OUTPUT_DIR/local-installation-summary.txt"
if grep -Fq '/modules/' "$DOCKER_LOG"; then exit 1; fi
PREPARED_KEY="$(grep '^PrivateKey' "$PREPARED_DIR/wireguard/config.conf")"
PREPARED_PEER="$(cat "$PREPARED_DIR/wireguard/peer1.conf")"
LAMP_CONFIG="$(cat "$PREPARED_DIR/lamp/docker-compose.yml")"
KUMA_CONFIG="$(cat "$PREPARED_DIR/uptime-kuma/docker-compose.yml")"
CORE_CHECKSUM="$(sha256sum "$LOCAL_BASM_ROOT/docker-compose.yml")"
prepare_full_profile
[[ "$(grep '^PrivateKey' "$PREPARED_DIR/wireguard/config.conf")" == "$PREPARED_KEY" ]]

(
  BASM_ROOT="$TEST_DIR/production-preparation"
  DEPLOYMENT_MODE=production
  BIND_ADDRESS=0.0.0.0
  BASM_CONTAINER_PREFIX=basm
  PRIMARY_DOMAIN=acme.example
  set_port_defaults standard
  prepare_full_profile
  grep -Fq '"0.0.0.0:8080:80"' "$BASM_ROOT/config/prepared-modules/lamp/docker-compose.yml"
  grep -Fq '"0.0.0.0:3001:3001"' "$BASM_ROOT/config/prepared-modules/uptime-kuma/docker-compose.yml"
  grep -Fq 'Endpoint = acme.example:51820' "$BASM_ROOT/config/prepared-modules/wireguard/peer1.conf"
  [[ ! -e "$BASM_ROOT/modules" ]]
  run_module_install lamp
  [[ -f "$BASM_ROOT/modules/lamp/docker-compose.yml" && ! -e "$BASM_ROOT/config/prepared-modules/lamp" ]]
  [[ -f "$BASM_ROOT/config/prepared-modules/uptime-kuma/docker-compose.yml" ]]
)
: > "$DOCKER_LOG"

# Basic -> full keeps core untouched and starts the runnable modules.
: > "$DOCKER_LOG"
unset HTTP_PORT HTTPS_PORT SMTP_PORT LAMP_PORT WIREGUARD_PORT UPTIME_KUMA_PORT
select_deployment < <(printf 'local\n')
load_deployment_env
upgrade_to_full
[[ "$HTTP_PORT" == 19080 && "$HTTPS_PORT" == 19443 && "$SMTP_PORT" == 12525 ]]
[[ "$LAMP_PORT" == 19081 && "$WIREGUARD_PORT" == 51825 && "$UPTIME_KUMA_PORT" == 19301 ]]
[[ "$(sha256sum "$LOCAL_BASM_ROOT/docker-compose.yml")" == "$CORE_CHECKSUM" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml")" == "$LAMP_CONFIG" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/uptime-kuma/docker-compose.yml")" == "$KUMA_CONFIG" ]]
[[ "$(grep '^PrivateKey' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf")" == "$PREPARED_KEY" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/wireguard/peer1.conf")" == "$PREPARED_PEER" ]]
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma"' "$LOCAL_BASM_ROOT/config/basm.env"
grep -Fqx "DB_ROOT_PASSWORD=\"$LOCAL_DB_PASSWORD\"" "$LOCAL_BASM_ROOT/config/basm.env"
[[ "$(stat -c '%a' "$LOCAL_BASM_ROOT/config/basm.env")" == 600 ]]
grep -Fq 'name: basm-local-lamp' "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq '"127.0.0.1:19081:80"' "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq 'ListenPort = 51825' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf"
grep -Fq "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml up -d" "$DOCKER_LOG"
grep -Fq "$LOCAL_BASM_ROOT/modules/uptime-kuma/docker-compose.yml up -d" "$DOCKER_LOG"
if grep -Fq "$LOCAL_BASM_ROOT/docker-compose.yml" "$DOCKER_LOG"; then exit 1; fi
if grep -Eq '(^| )pull( |$)' "$DOCKER_LOG"; then exit 1; fi
grep -Fq 'Installed Modules: basm lamp wireguard uptime-kuma' "$OUTPUT_DIR/local-installation-summary.txt"

# Re-running the upgrade is idempotent.
upgrade_to_full
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma"' "$LOCAL_BASM_ROOT/config/basm.env"

# A blank module selection on a rerun keeps the existing full selection.
(
  select_deployment < <(printf 'local\n') >/dev/null
  select_modules < <(printf '\n') >/dev/null
  [[ "$BASM_MODULES" == "basm lamp wireguard uptime-kuma" ]]
  select_modules < <(printf 'full\n') >/dev/null
  [[ "$BASM_MODULES" == "$BASM_FULL_MODULES" ]]
)

# Compose never sees exported deployment secrets, so --env-file always wins.
(
  export DB_ROOT_PASSWORD=leaked-secret BASM_ROOT=/wrong DOCKER_HOST=unix:///keep.sock
  docker() { printenv DB_ROOT_PASSWORD BASM_ROOT > "$TEST_DIR/compose-env" || true; printenv DOCKER_HOST > "$TEST_DIR/docker-host"; }
  basm_compose version
  [[ ! -s "$TEST_DIR/compose-env" ]]
  [[ "$(< "$TEST_DIR/docker-host")" == unix:///keep.sock ]]
  [[ "$DB_ROOT_PASSWORD" == leaked-secret ]]
)

# Generated modules are usable: LAMP serves a page and WireGuard has real keys.
grep -Fq -- '- ./www:/var/www/html' "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml"
[[ -s "$LOCAL_BASM_ROOT/modules/lamp/www/index.html" ]]
if grep -q CHANGE_ME "$LOCAL_BASM_ROOT/modules/wireguard/config.conf"; then exit 1; fi
grep -Eq '^PrivateKey = [A-Za-z0-9+/]{43}=$' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf"
grep -Fq 'Endpoint = 127.0.0.1:51825' "$LOCAL_BASM_ROOT/modules/wireguard/peer1.conf"
[[ "$(stat -c '%a' "$LOCAL_BASM_ROOT/modules/wireguard/peer1.conf")" == 600 ]]
WG_KEY="$(grep '^PrivateKey' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf")"
( source "$ROOT_DIR/modules/wireguard.sh"; module_install )
[[ "$(grep '^PrivateKey' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf")" == "$WG_KEY" ]]
(
  source "$ROOT_DIR/modules/wireguard.sh"
  WIREGUARD_PORT=51826
  BIND_ADDRESS=192.168.1.50
  module_install
  grep -Fq 'ListenPort = 51826' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf"
  grep -Fq 'Endpoint = 192.168.1.50:51826' "$LOCAL_BASM_ROOT/modules/wireguard/peer1.conf"
  [[ "$(grep '^PrivateKey' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf")" == "$WG_KEY" ]]
)
( source "$ROOT_DIR/modules/wireguard.sh"; module_install )
[[ "$(grep -c 'start_period: 300s' "$LOCAL_BASM_ROOT/docker-compose.yml")" == 3 ]]
if grep -Fq docker.sock "$LOCAL_BASM_ROOT/docker-compose.yml"; then exit 1; fi
grep -Fq 'NEXTCLOUD_TRUSTED_DOMAINS: "cloud.localhost localhost 127.0.0.1"' "$LOCAL_BASM_ROOT/docker-compose.yml"

# Cancelling a promotion leaves the local install intact.
( promote_to_production < <(printf 'acme.example\nno\n') ) && exit 1
[[ -f "$LOCAL_BASM_ROOT/config/basm.env" && ! -e "$PRODUCTION_BASM_ROOT" ]]

# Promotion refuses to overwrite an existing production stack.
mkdir -p "$PRODUCTION_BASM_ROOT"
touch "$PRODUCTION_BASM_ROOT/docker-compose.yml"
( promote_to_production < <(printf 'acme.example\npromote\n') ) 2>/dev/null && exit 1
[[ -f "$LOCAL_BASM_ROOT/config/basm.env" ]]
rm -rf "$PRODUCTION_BASM_ROOT"

# A failed production setup rolls back and restores the local install.
: > "$DOCKER_LOG"
docker() {
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  [[ "$*" != *"$PRODUCTION_BASM_ROOT/docker-compose.yml"*" up -d"* ]]
}
( promote_to_production < <(printf 'acme.example\npromote\n\n\n\n\n\n\n\n\n\n\n') ) 2>/dev/null && exit 1
[[ -f "$LOCAL_BASM_ROOT/config/basm.env" && -d "$LOCAL_BASM_ROOT/data" && ! -e "$PRODUCTION_BASM_ROOT" ]]
grep -Fqx "DB_ROOT_PASSWORD=\"$LOCAL_DB_PASSWORD\"" "$LOCAL_BASM_ROOT/config/basm.env"
grep -Fq "$LOCAL_BASM_ROOT/docker-compose.yml --env-file $LOCAL_BASM_ROOT/config/basm.env down --remove-orphans" "$DOCKER_LOG"
if grep -Fq "$LOCAL_BASM_ROOT/docker-compose.yml --env-file $LOCAL_BASM_ROOT/config/basm.env down -v" "$DOCKER_LOG"; then exit 1; fi
[[ "$(grep -Fc "$LOCAL_BASM_ROOT/docker-compose.yml --env-file $LOCAL_BASM_ROOT/config/basm.env up -d" "$DOCKER_LOG")" == 1 ]]
grep -Fq "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml up -d" "$DOCKER_LOG"
docker() { printf '%s\n' "$*" >> "$DOCKER_LOG"; }

# Promotion purges local, creates fresh production, and downloads nothing new.
: > "$DOCKER_LOG"
mkdir -p "$TEST_DIR/prod-backups"
promote_to_production < <(printf 'bad domain\nacme.example\npromote\n\n\n\n\n%s\n\n\n\n\n\n' "$TEST_DIR/prod-backups")
[[ ! -e "$LOCAL_BASM_ROOT" && ! -e "$OUTPUT_DIR/local-installation-summary.txt" ]]
[[ "$(grep -n "$LOCAL_BASM_ROOT/docker-compose.yml --env-file $LOCAL_BASM_ROOT/config/basm.env down -v" "$DOCKER_LOG" | cut -d: -f1)" -gt \
   "$(grep -n "$PRODUCTION_BASM_ROOT/docker-compose.yml --env-file .* up -d" "$DOCKER_LOG" | tail -1 | cut -d: -f1)" ]]
grep -Fq "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml down -v --remove-orphans" "$DOCKER_LOG"
grep -Fq "$LOCAL_BASM_ROOT/modules/uptime-kuma/docker-compose.yml down -v --remove-orphans" "$DOCKER_LOG"
grep -Fq "$LOCAL_BASM_ROOT/docker-compose.yml --env-file $LOCAL_BASM_ROOT/config/basm.env down -v --remove-orphans" "$DOCKER_LOG"
if grep -Eq -- '(^| )(pull|--rmi)( |$)' "$DOCKER_LOG"; then exit 1; fi
[[ ! -s "$APT_LOG" ]]

PROD_ENV="$PRODUCTION_BASM_ROOT/config/basm.env"
[[ "$(stat -c '%a' "$PROD_ENV")" == 600 ]]
grep -Fqx 'DEPLOYMENT_MODE="production"' "$PROD_ENV"
grep -Fqx 'BIND_ADDRESS="0.0.0.0"' "$PROD_ENV"
grep -Fqx 'BASM_CONTAINER_PREFIX="basm"' "$PROD_ENV"
grep -Fqx 'PRIMARY_DOMAIN="acme.example"' "$PROD_ENV"
grep -Fqx 'ERP_URL="erp.acme.example"' "$PROD_ENV"
grep -Fqx 'COMPANY_NAME="Acme Ltd"' "$PROD_ENV"
grep -Fqx 'ADMIN_EMAIL="ops@acme.dk"' "$PROD_ENV"
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma"' "$PROD_ENV"
grep -Fqx 'PORT_PROFILE="standard"' "$PROD_ENV"
grep -Fqx 'HTTP_PORT=80' "$PROD_ENV"
grep -Fqx 'SMTP_PORT=25' "$PROD_ENV"
grep -Fqx 'POSTAL_WEB_PROTOCOL="https"' "$PROD_ENV"
grep -Fqx "BACKUP_LOCATION=\"$TEST_DIR/prod-backups\"" "$PROD_ENV"
if grep -Fq "$LOCAL_DB_PASSWORD" "$PROD_ENV"; then exit 1; fi
if grep -Fq basm-local "$PRODUCTION_BASM_ROOT/docker-compose.yml"; then exit 1; fi
grep -Fqx 'certificatesResolvers:' "$PRODUCTION_BASM_ROOT/config/traefik-static.yml"
grep -Fqx '  dashboard: true' "$PRODUCTION_BASM_ROOT/config/traefik-static.yml"
grep -Fq 'web_protocol: "https"' "$PRODUCTION_BASM_ROOT/config/postal/postal.yml"
grep -Fq 'name: basm-lamp' "$PRODUCTION_BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq '"0.0.0.0:8080:80"' "$PRODUCTION_BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq "$PRODUCTION_BASM_ROOT/docker-compose.yml --env-file $PROD_ENV up -d" "$DOCKER_LOG"
grep -Fq "$PRODUCTION_BASM_ROOT/modules/uptime-kuma/docker-compose.yml up -d" "$DOCKER_LOG"
grep -Fq 'https://erp.acme.example:443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq 'LAMP: http://acme.example:8080' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq 'NEXTCLOUD_TRUSTED_DOMAINS: "cloud.acme.example"' "$PRODUCTION_BASM_ROOT/docker-compose.yml"
grep -Fq 'redirect-to-https' "$PRODUCTION_BASM_ROOT/config/traefik.yml"
grep -Fq 'port: "443"' "$PRODUCTION_BASM_ROOT/config/traefik.yml"
grep -Fq 'Endpoint = acme.example:51820' "$PRODUCTION_BASM_ROOT/modules/wireguard/peer1.conf"

# Production rejects placeholder contacts that Let's Encrypt would refuse.
validate_production_email ops@acme.dk
for email in admin@example.com ops@Example.ORG it@basm.test a@b.invalid; do
  if validate_production_email "$email"; then exit 1; fi
done

# Only missing packages are installed, and installed ones are never upgraded.
dpkg-query() { [[ "$3" == gettext-base ]] || printf 'install ok installed'; }
ensure_packages curl gettext-base
grep -Fqx 'update' "$APT_LOG"
grep -Fqx 'install -y --no-upgrade gettext-base' "$APT_LOG"

printf 'Lifecycle tests passed.\n'
