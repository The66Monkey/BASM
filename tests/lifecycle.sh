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
systemctl() { :; }
port_in_use() { return 1; }
check_debian() { :; }
export -f docker

(
  BASM_ROOT="$TEST_DIR/rustdesk-root"
  DOCKER_LOG="$TEST_DIR/rustdesk-docker.log"
  BASM_MODULES='basm rustdesk'
  DEPLOYMENT_MODE=local
  BIND_ADDRESS=127.0.0.1
  BASM_CONTAINER_PREFIX=basm-local
  set_port_defaults local
  validate_port_plan
  source "$MODULES_DIR/rustdesk.sh"
  module_install
  module_start
  COMPOSE_FILE="$BASM_ROOT/modules/rustdesk/docker-compose.yml"
  grep -Fq '"127.0.0.1:22115:21115"' "$COMPOSE_FILE"
  grep -Fq '"127.0.0.1:22116:21116/udp"' "$COMPOSE_FILE"
  grep -Fq '"127.0.0.1:22117:21117"' "$COMPOSE_FILE"
  grep -Fq '"127.0.0.1:22117", "-k", "_"' "$COMPOSE_FILE"
  [[ "$(stat -c '%a' "$BASM_ROOT/modules/rustdesk/data")" == 700 ]]
  printf 'preserved-key\n' > "$BASM_ROOT/modules/rustdesk/data/id_ed25519"
  module_install
  grep -Fxq preserved-key "$BASM_ROOT/modules/rustdesk/data/id_ed25519"
  if grep -Eq '21118|21119|network_mode' "$COMPOSE_FILE"; then exit 1; fi
  grep -Fq "$COMPOSE_FILE up -d" "$DOCKER_LOG"
  RUSTDESK_RELAY_PORT="$HTTP_PORT"
  if validate_port_plan; then exit 1; fi
  set_port_defaults local
  RUSTDESK_NAT_PORT=22114
  if validate_port_plan; then exit 1; fi
  RUSTDESK_NAT_PORT=invalid
  if validate_port_plan; then exit 1; fi
  set_port_defaults standard
  BASM_MODULES='basm rustdesk wireguard'
  WIREGUARD_PORT="$RUSTDESK_ID_PORT"
  if validate_port_plan; then exit 1; fi
  BASM_MODULES=basm
  select_modules <<< '8'
  [[ "$BASM_MODULES" == 'basm rustdesk' ]]
  DEPLOYMENT_MODE=production
  BIND_ADDRESS=0.0.0.0
  PRIMARY_DOMAIN=acme.example
  module_install
  grep -Fq '"acme.example:21117"' "$COMPOSE_FILE"
  grep -Fq '"0.0.0.0:21116:21116"' "$COMPOSE_FILE"
)

(
  BASM_ROOT="$TEST_DIR/fluxer-root"
  FLUXER_TEST_LOG="$TEST_DIR/fluxer-module.log"
  FLUXER_DOMAIN=chat.acme.example
  FLUXER_PROXY_PORT=18088
  FLUXER_VOICE_TCP_PORT=17881
  FLUXER_VOICE_UDP_PORT=17882
  BASM_CONTAINER_PREFIX=basm
  COMPANY_NAME='Acme Ltd'
  DEPLOYMENT_MODE=production
  BACKUP_LOCATION="$TEST_DIR/fluxer-backups"
  : > "$FLUXER_TEST_LOG"
  docker() { printf '172.28.0.1\n'; }
  curl() {
    local destination=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi
    done
    printf '#!/usr/bin/env bash\n' > "$destination"
  }
  bash() { printf 'installer %s\n' "$*" >> "$FLUXER_TEST_LOG"; }
  rexctl() { printf 'rexctl %s\n' "$*" >> "$FLUXER_TEST_LOG"; }
  source "$MODULES_DIR/fluxer.sh"
  module_install
  module_start
  module_update
  module_stop
  module_uninstall
  grep -Fq 'install --dir '"$BASM_ROOT"'/modules/fluxer --project basm-fluxer --domain chat.acme.example' "$FLUXER_TEST_LOG"
  grep -Fq -- '--registration invite --sign-in username --skip-email --setup terminal' "$FLUXER_TEST_LOG"
  grep -Fq -- '--behind-proxy --bind 172.28.0.1:18088' "$FLUXER_TEST_LOG"
  grep -Fq -- '--voice-tcp-port 17881 --voice-udp-port 17882' "$FLUXER_TEST_LOG"
  [[ "$(stat -c '%a' "$BACKUP_LOCATION/fluxer")" == 700 ]]
  grep -Fq 'rexctl backup location '"$BACKUP_LOCATION"'/fluxer --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  grep -Fq 'rexctl backup keep 7 --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  grep -Fq 'rexctl start --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  grep -Fq 'rexctl upgrade --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  grep -Fq 'rexctl stop --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  grep -Fq 'rexctl uninstall --confirm chat.acme.example --dir '"$BASM_ROOT"'/modules/fluxer' "$FLUXER_TEST_LOG"
  [[ ! -e "$BASM_ROOT/modules/fluxer/fluxer-install.sh" ]]
  if ( DEPLOYMENT_MODE=local; module_install ); then exit 1; fi
)

(
  ACTION_ROOT="$TEST_DIR/fluxer-action"
  ACTION_LOG="$TEST_DIR/fluxer-action.log"
  mkdir -p "$ACTION_ROOT/config"
  printf 'BASM_ROOT="%s"\nBASM_MODULES="basm fluxer"\nFLUXER_DOMAIN="chat.acme.example"\n' \
    "$ACTION_ROOT" > "$ACTION_ROOT/config/basm.env"
  rexctl() { printf '%s\n' "$*" >> "$ACTION_LOG"; }
  export -f rexctl
  unset MODULES_DIR
  run_module_action_for_root "$ACTION_ROOT" fluxer stop
  grep -Fq 'stop --dir '"$ACTION_ROOT"'/modules/fluxer' "$ACTION_LOG"
)

(
  BASM_MODULES='basm fluxer'
  PRIMARY_DOMAIN=acme.example
  ERP_URL=erp.acme.example
  MAIL_URL=mail.acme.example
  CLOUD_URL=cloud.acme.example
  FLUXER_DOMAIN=chat.acme.example
  DNS_FILE="$TEST_DIR/fluxer-dns.txt"
  write_dns_records "$DNS_FILE"
  grep -Fq '(Fluxer chat: chat.acme.example)' "$DNS_FILE"
  grep -Fq '"subname":"chat","type":"A","ttl":3600,"records":["$PUBLIC_IP"]' "$DNS_FILE"
  BASM_MODULES=basm
  write_dns_records "$DNS_FILE"
  if grep -Fq 'chat               A      PUBLIC_IP' "$DNS_FILE"; then exit 1; fi
)

(
  set_port_defaults standard
  BASM_MODULES='basm fluxer'
  validate_port_plan
  FLUXER_VOICE_TCP_PORT="$HTTP_PORT"
  if validate_port_plan; then exit 1; fi
  FLUXER_VOICE_TCP_PORT=17881
  BASM_MODULES='basm fluxer wireguard'
  WIREGUARD_PORT="$FLUXER_VOICE_UDP_PORT"
  if validate_port_plan; then exit 1; fi
)

(
  BASM_ROOT="$TEST_DIR/fluxer-render"
  COMPANY_NAME=Acme
  mkdir -p "$BASM_ROOT/config"
  DEPLOYMENT_MODE=production
  BIND_ADDRESS=0.0.0.0
  BASM_CONTAINER_PREFIX=basm
  PRIMARY_DOMAIN=acme.example
  ERP_URL=erp.acme.example
  MAIL_URL=mail.acme.example
  CLOUD_URL=cloud.acme.example
  FLUXER_DOMAIN=chat.acme.example
  ADMIN_EMAIL=ops@acme.dk
  BASM_MODULES='basm fluxer'
  set_port_defaults standard
  render_stack
  grep -Fq 'Host(`chat.acme.example`)' "$BASM_ROOT/config/traefik.yml"
  grep -Fq 'http://host.docker.internal:8088' "$BASM_ROOT/config/traefik.yml"
  grep -Fq 'host.docker.internal:host-gateway' "$BASM_ROOT/docker-compose.yml"
  jq -e '.http.routers | has("erp") and has("mail") and has("cloud") and has("fluxer")' "$BASM_ROOT/config/traefik.yml"
  BASM_MODULES=basm
  render_stack
  if grep -Fq 'fluxer-service' "$BASM_ROOT/config/traefik.yml"; then exit 1; fi
)

(
  BASM_ROOT="$TEST_DIR/fluxer-maintenance"
  BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
  BASM_MODULES='basm fluxer'
  BACKUP_LOCATION="$BASM_ROOT/backups"
  BASM_CRON_DIR="$TEST_DIR/fluxer-cron"
  LOG_FILE="$TEST_DIR/fluxer-maintenance.log"
  install_auto_updates
  [[ -s "$BASM_ROOT/maintenance/modules/fluxer.sh" ]]
  [[ "$(stat -c '%a' "$BASM_ROOT/maintenance/modules/fluxer.sh")" == 600 ]]
  [[ "$(stat -c '%a' "$BASM_ROOT/maintenance/bin/basm")" == 700 ]]
  bash -n "$BASM_ROOT/maintenance/bin/basm"
  grep -Fq '0 2 * * * root /bin/bash' "$(backup_cron_file "$BASM_ROOT")"
  [[ ! -e "$(fluxer_backup_cron_file "$BASM_ROOT")" ]]
)

LOCAL_BASM_ROOT="$TEST_DIR/basm-local"
PRODUCTION_BASM_ROOT="$TEST_DIR/basm"
OUTPUT_DIR="$TEST_DIR/output"
BASM_CRON_DIR="$TEST_DIR/cron.d"
mkdir -p "$OUTPUT_DIR"

# Basic local install: blank module selection keeps core only.
run_wizard < <(printf 'local\n\nAcme Ltd\nops@acme.dk\n\n\n\n\ncustom\n19080\n19443\n12525\n19081\n51825\n19301\n22115\n22116\n22117\n')
[[ "$BASM_MODULES" == basm ]]
configure_system
install_selected_modules
write_summary
LOCAL_CRON_FILE="$(update_cron_file "$LOCAL_BASM_ROOT")"
grep -Fq '0 3 1 1,7 * root /bin/bash' "$LOCAL_CRON_FILE"
grep -Fq "$LOCAL_BASM_ROOT/maintenance/run-updates.sh" "$LOCAL_CRON_FILE"
[[ "$(stat -c '%a' "$LOCAL_CRON_FILE")" == 644 ]]
[[ "$(stat -c '%a' "$LOCAL_BASM_ROOT/maintenance/run-updates.sh")" == 700 ]]
[[ -s "$LOCAL_BASM_ROOT/maintenance/update.sh" && -s "$LOCAL_BASM_ROOT/maintenance/modules/core.sh" ]]
touch "$LOCAL_BASM_ROOT/config/disable-auto-updates"
bash "$LOCAL_BASM_ROOT/maintenance/run-updates.sh"
[[ ! -e "$LOCAL_BASM_ROOT/logs/automatic-updates.log" ]]
[[ "$(find "$BASM_CRON_DIR" -type f | wc -l)" == 3 ]]
USER_HANDOVER="$LOCAL_BASM_ROOT/handover/for-the-user.txt"
IT_HANDOVER="$LOCAL_BASM_ROOT/handover/for-it.txt"
[[ "$(stat -c '%a' "$LOCAL_BASM_ROOT/handover")" == 700 ]]
[[ "$(stat -c '%a' "$USER_HANDOVER")" == 600 ]]
[[ "$(stat -c '%a' "$IT_HANDOVER")" == 600 ]]
grep -Fq "Initial password: $ERP_ADMIN_PASSWORD" "$USER_HANDOVER"
grep -Fq "Initial password: $NEXTCLOUD_ADMIN_PASSWORD" "$USER_HANDOVER"
grep -Fq "Initial password: $POSTAL_ADMIN_PASSWORD" "$USER_HANDOVER"
grep -Fq "Username: $NEXTCLOUD_ADMIN_USER" "$USER_HANDOVER"
grep -Fq "Username: $ADMIN_EMAIL" "$USER_HANDOVER"
grep -Fq "Backup encryption password: $RESTIC_PASSWORD" "$USER_HANDOVER"
grep -Fq 'http://erp.localhost:19080' "$USER_HANDOVER"
grep -Fq 'Need professional support? Scandinavian Hacking' "$USER_HANDOVER"
grep -Fq 'https://scandinavianhacking.se/' "$USER_HANDOVER"
grep -Fq 'DO NOT FORWARD ANY ROUTER PORTS' "$IT_HANDOVER"
if grep -Fq "$ERP_ADMIN_PASSWORD" "$OUTPUT_DIR/local-installation-summary.txt"; then exit 1; fi
if grep -Fq 'Monitoring (Uptime Kuma)' "$USER_HANDOVER"; then exit 1; fi
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
  MANAGEMENT_BIND_ADDRESS=127.0.0.1
  prepare_full_profile
  grep -Fq '"127.0.0.1:8080:80"' "$BASM_ROOT/config/prepared-modules/lamp/docker-compose.yml"
  grep -Fq '"127.0.0.1:3001:3001"' "$BASM_ROOT/config/prepared-modules/uptime-kuma/docker-compose.yml"
  grep -Fq 'Endpoint = acme.example:51820' "$BASM_ROOT/config/prepared-modules/wireguard/peer1.conf"
  [[ ! -e "$BASM_ROOT/modules" ]]
  run_module_install lamp
  [[ -f "$BASM_ROOT/modules/lamp/docker-compose.yml" && ! -e "$BASM_ROOT/config/prepared-modules/lamp" ]]
  [[ -f "$BASM_ROOT/config/prepared-modules/uptime-kuma/docker-compose.yml" ]]
)
: > "$DOCKER_LOG"

# Local full rejects Fluxer before changing the deployment; safe modules remain available.
: > "$DOCKER_LOG"
unset HTTP_PORT HTTPS_PORT SMTP_PORT LAMP_PORT WIREGUARD_PORT UPTIME_KUMA_PORT
select_deployment < <(printf 'local\n')
load_deployment_env
LOCAL_ENV_CHECKSUM="$(sha256sum "$BASM_ENV_FILE")"
if (upgrade_to_full); then exit 1; fi
[[ "$(sha256sum "$BASM_ENV_FILE")" == "$LOCAL_ENV_CHECKSUM" ]]
[[ ! -s "$DOCKER_LOG" ]]
upgrade_modules $BASM_PREPARED_MODULES
[[ "$HTTP_PORT" == 19080 && "$HTTPS_PORT" == 19443 && "$SMTP_PORT" == 12525 ]]
[[ "$LAMP_PORT" == 19081 && "$WIREGUARD_PORT" == 51825 && "$UPTIME_KUMA_PORT" == 19301 ]]
[[ "$(sha256sum "$LOCAL_BASM_ROOT/docker-compose.yml")" == "$CORE_CHECKSUM" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/lamp/docker-compose.yml")" == "$LAMP_CONFIG" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/uptime-kuma/docker-compose.yml")" == "$KUMA_CONFIG" ]]
[[ "$(grep '^PrivateKey' "$LOCAL_BASM_ROOT/modules/wireguard/config.conf")" == "$PREPARED_KEY" ]]
[[ "$(cat "$LOCAL_BASM_ROOT/modules/wireguard/peer1.conf")" == "$PREPARED_PEER" ]]
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma rustdesk"' "$LOCAL_BASM_ROOT/config/basm.env"
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
grep -Fq 'Monitoring (Uptime Kuma)' "$USER_HANDOVER"
grep -Fq 'http://127.0.0.1:19301' "$USER_HANDOVER"
grep -Fq "Initial password: $ERP_ADMIN_PASSWORD" "$USER_HANDOVER"
[[ -f "$LOCAL_BASM_ROOT/config/disable-auto-updates" ]]
[[ "$(find "$BASM_CRON_DIR" -type f | wc -l)" == 3 ]]
grep -Fq 'AUTOMATIC MAINTENANCE' "$USER_HANDOVER"
grep -Fq '8. AUTOMATIC UPDATES' "$IT_HANDOVER"

# Re-running the upgrade is idempotent.
upgrade_modules $BASM_PREPARED_MODULES
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma rustdesk"' "$LOCAL_BASM_ROOT/config/basm.env"

# A blank module selection on a rerun keeps the existing full selection.
(
  select_deployment < <(printf 'local\n') >/dev/null
  select_modules < <(printf '\n') >/dev/null
  [[ "$BASM_MODULES" == "basm lamp wireguard uptime-kuma rustdesk" ]]
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
[[ "$(stat -c %a "$LOCAL_BASM_ROOT/modules/lamp/www")" == 755 ]]
[[ "$(stat -c %a "$LOCAL_BASM_ROOT/modules/lamp/www/index.html")" == 644 ]]
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
[[ ! -e "$LOCAL_CRON_FILE" ]]
[[ -f "$(update_cron_file "$PRODUCTION_BASM_ROOT")" ]]
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
grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma rustdesk"' "$PROD_ENV"
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
grep -Fq '"127.0.0.1:8080:80"' "$PRODUCTION_BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq "$PRODUCTION_BASM_ROOT/docker-compose.yml --env-file $PROD_ENV up -d" "$DOCKER_LOG"
grep -Fq "$PRODUCTION_BASM_ROOT/modules/uptime-kuma/docker-compose.yml up -d" "$DOCKER_LOG"
grep -Fq 'https://erp.acme.example:443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq 'LAMP: http://127.0.0.1:8080' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq 'NEXTCLOUD_TRUSTED_DOMAINS: "cloud.acme.example"' "$PRODUCTION_BASM_ROOT/docker-compose.yml"
grep -Fq 'redirect-to-https' "$PRODUCTION_BASM_ROOT/config/traefik.yml"
jq -e '.http.middlewares["redirect-to-https"].redirectScheme.port == "443"' "$PRODUCTION_BASM_ROOT/config/traefik.yml" >/dev/null
grep -Fq 'Endpoint = acme.example:51820' "$PRODUCTION_BASM_ROOT/modules/wireguard/peer1.conf"
USER_HANDOVER="$PRODUCTION_BASM_ROOT/handover/for-the-user.txt"
IT_HANDOVER="$PRODUCTION_BASM_ROOT/handover/for-it.txt"
[[ ! -e "$LOCAL_BASM_ROOT/handover" ]]
grep -Fq 'https://erp.acme.example:443' "$USER_HANDOVER"
grep -Fq "Initial password: $ERP_ADMIN_PASSWORD" "$USER_HANDOVER"
grep -Fq 'HTTP           TCP         80               80' "$IT_HANDOVER"
grep -Fq 'Postal SMTP    TCP         25               25' "$IT_HANDOVER"
if grep -Fq "$LOCAL_DB_PASSWORD" "$USER_HANDOVER"; then exit 1; fi
if grep -Fq "$ERP_ADMIN_PASSWORD" "$IT_HANDOVER" "$OUTPUT_DIR/installation-summary.txt"; then exit 1; fi
(
  HTTP_PORT=19080 HTTPS_PORT=19443 SMTP_PORT=12525
  chmod 644 "$USER_HANDOVER" "$IT_HANDOVER"
  write_summary
  grep -Fq 'https://erp.acme.example:19443' "$USER_HANDOVER"
  grep -Fq 'HTTP           TCP         19080               19080' "$IT_HANDOVER"
  grep -Fq 'Postal SMTP    TCP         25               12525' "$IT_HANDOVER"
  grep -Fq 'ALSO forward external TCP 80 to internal 19080' "$IT_HANDOVER"
  grep -Fq 'ALSO forward external TCP 443 to internal 19443' "$IT_HANDOVER"
  [[ "$(stat -c '%a' "$USER_HANDOVER")" == 600 ]]
  [[ "$(stat -c '%a' "$IT_HANDOVER")" == 600 ]]
)

(
  upgrade_modules rustdesk
  grep -Fqx 'BASM_MODULES="basm lamp wireguard uptime-kuma rustdesk"' "$PROD_ENV"
  grep -Fqx 'RUSTDESK_ID_PORT=21116' "$PROD_ENV"
  grep -Fq 'RustDesk ID server: acme.example:21116' "$OUTPUT_DIR/installation-summary.txt"
  grep -Fq 'ID server: acme.example:21116' "$USER_HANDOVER"
  grep -Fq 'RustDesk ID    TCP/UDP     21116' "$IT_HANDOVER"
  grep -Fq 'complete BASM backup includes '"$BASM_ROOT"'/modules/rustdesk/data' "$IT_HANDOVER"
  load_deployment_env
  [[ "$RUSTDESK_RELAY_PORT" == 21117 ]]
  BASM_MODULES+=' keepass'
  sync_keepass() { printf 'test-master-password\n'; }
  write_summary
  grep -Fq 'YOUR KEEPASS ACCESS' "$USER_HANDOVER"
  grep -Fq 'ID server: acme.example:21116' "$USER_HANDOVER"
)

(
  FULL_ACTIONS="$TEST_DIR/full-actions.log"
  FULL_CORE_CHECKSUM="$(sha256sum "$BASM_ROOT/docker-compose.yml")"
  load_deployment_env
  run_module_install() { printf '%s\n' "$1" >> "$FULL_ACTIONS"; }
  sync_keepass() { printf 'test-master-password\n'; }
  upgrade_to_full
  for module_name in $BASM_FULL_MODULES; do module_selected "$module_name"; done
  [[ "$(sha256sum "$BASM_ROOT/docker-compose.yml")" == "$FULL_CORE_CHECKSUM" ]]
  [[ "$(wc -l < "$FULL_ACTIONS")" == 6 ]]
  for module_name in lamp wireguard uptime-kuma fluxer keepass rustdesk; do
    grep -Fxq "$module_name" "$FULL_ACTIONS"
  done
  grep -Fqx "BASM_MODULES=\"$BASM_MODULES\"" "$PROD_ENV"
  grep -Fq 'YOUR KEEPASS ACCESS' "$USER_HANDOVER"
  grep -Fq 'ID server: acme.example:21116' "$USER_HANDOVER"
  select_modules <<< full >/dev/null
  [[ "$BASM_MODULES" == "$BASM_FULL_MODULES" ]]
)

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
