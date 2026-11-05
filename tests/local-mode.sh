#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/modules"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/modules/core.sh"

for answer in s S static STATIC; do
  [[ "$(prompt_ip_mode <<< "$answer")" == static ]]
done
for answer in n N non-static NON-STATIC; do
  [[ "$(prompt_ip_mode <<< "$answer")" == non-static ]]
done
[[ "$(prompt_ip_mode <<< '')" == static ]]
[[ "$(prompt_ip_mode non-static <<< '')" == non-static ]]
[[ "$(printf 'invalid\nN\n' | prompt_ip_mode)" == non-static ]]

BASM_PROFILE_DIR="$TEST_DIR/profile.d"
install_login_banner
cmp "$ROOT_DIR/templates/profile.d/basm.sh" "$BASM_PROFILE_DIR/basm.sh"
[[ "$(stat -c '%a' "$BASM_PROFILE_DIR/basm.sh")" == 644 ]]

for banner_mode in running empty denied missing; do
  banner_output="$(BANNER_MODE="$banner_mode" bash --noprofile --norc -ic '
    docker() {
      case "$BANNER_MODE" in
        running) printf "basm-one\nbasm-two\n" ;;
        empty) return 0 ;;
        denied) printf "permission denied\n" >&2; return 1 ;;
      esac
    }
    command() {
      if [[ "$BANNER_MODE" == missing && "$*" == "-v docker" ]]; then
        return 1
      fi
      builtin command "$@"
    }
    source "$1"
  ' bash "$BASM_PROFILE_DIR/basm.sh" 2>/dev/null)"
  case "$banner_mode" in
    running) grep -Fq 'Stack: 2 running container(s)' <<< "$banner_output" ;;
    empty) grep -Fq 'Stack: 0 running container(s)' <<< "$banner_output" ;;
    denied) grep -Fq 'Stack: Status unavailable to this login; check with sudo' <<< "$banner_output" ;;
    missing) grep -Fq 'Stack: Docker command not installed' <<< "$banner_output" ;;
  esac
done
[[ -z "$(bash --noprofile --norc -c 'source "$1"' bash "$BASM_PROFILE_DIR/basm.sh")" ]]

previous_password=""
for attempt in {1..10}; do
  password="$(generate_password)"
  [[ "$password" =~ ^[A-Za-z0-9]{32}$ ]]
  [[ "$password" =~ [A-Z] && "$password" =~ [a-z] && "$password" =~ [0-9] ]]
  [[ "$password" != "$previous_password" ]]
  previous_password="$password"
done
[[ "$(generate_secret)" =~ ^[0-9a-f]{64}$ ]]

(
set_port_defaults standard
[[ "$HTTP_PORT" == 80 && "$HTTPS_PORT" == 443 && "$LAMP_PORT" == 8080 ]]
BASM_MODULES='basm lamp uptime-kuma wireguard'
validate_port_plan
LAMP_PORT=80
if validate_port_plan; then exit 1; fi
set_port_defaults local
[[ "$HTTP_PORT" == 18080 && "$UPTIME_KUMA_PORT" == 18301 && "$WIREGUARD_PORT" == 18520 ]]
validate_port_plan
DEPLOYMENT_MODE=local
configure_ports < <(printf 'custom\n9000\n9443\n2526\n12465\n12993\n18082\n9001\n9301\n51822\n22115\n22116\n22117\n')
[[ "$HTTP_PORT" == 9000 && "$HTTPS_PORT" == 9443 && "$SMTP_PORT" == 2526 && "$LAMP_PORT" == 9001 && "$UPTIME_KUMA_PORT" == 9301 && "$WIREGUARD_PORT" == 51822 ]]
for port in 0 65536 080 abc; do
  if validate_port "$port"; then exit 1; fi
done

# A base install plans all future module ports and rejects future TCP collisions.
BASM_MODULES=basm
configure_ports < <(printf 'custom\n9000\n9443\n2526\n12465\n12993\n18082\n9000\n51822\n9301\n22115\n22116\n22117\ncustom\n9000\n9443\n2526\n12465\n12993\n18082\n9001\n51822\n9301\n22115\n22116\n22117\n')
[[ "$BASM_MODULES" == basm ]]
[[ "$LAMP_PORT" == 9001 && "$WIREGUARD_PORT" == 51822 && "$UPTIME_KUMA_PORT" == 9301 ]]

set_port_defaults standard
BASM_MODULES='basm fluxer wireguard'
FLUXER_VOICE_UDP_PORT=51820
if validate_port_plan; then exit 1; fi
FLUXER_VOICE_UDP_PORT=17882
FLUXER_VOICE_TCP_PORT=80
if validate_port_plan; then exit 1; fi

BASM_MODULES=basm
select_modules < <(printf '5\n') >/dev/null 2>"$TEST_DIR/vaultwarden-warning"
[[ "$BASM_MODULES" == basm ]]
grep -Fq 'Vaultwarden is deprecated' "$TEST_DIR/vaultwarden-warning"
(
  BASM_ROOT="$TEST_DIR/vaultwarden-legacy"
  source "$ROOT_DIR/modules/vaultwarden.sh"
  module_install 2>"$TEST_DIR/vaultwarden-module-warning"
  [[ ! -e "$BASM_ROOT/modules/vaultwarden" ]]
  grep -Fq 'Vaultwarden is deprecated' "$TEST_DIR/vaultwarden-module-warning"
)
)

for address in 127.0.0.1 10.0.0.5 192.168.1.5 172.16.0.1 172.31.255.254; do
  validate_local_bind_address "$address"
done
for address in 0.0.0.0 8.8.8.8 172.32.0.1 192.168.1.256 10.00.0.1 localhost ::1; do
  if validate_local_bind_address "$address"; then
    printf 'Unsafe address accepted: %s\n' "$address" >&2
    exit 1
  fi
done

[[ "$(printf 'not-a-port\n8080\n' | prompt_value Port 80 '[[ "$1" =~ ^[0-9]+$ ]]')" == 8080 ]]
[[ "$(printf 'invalid\nadmin@example.com\n' | prompt_value Email '' 'validate_email "$1"')" == admin@example.com ]]
validate_admin_username basm-admin
if validate_admin_username 'invalid user'; then exit 1; fi
validate_company_name 'Example Business, Inc.'
if validate_company_name 'Example "Business"'; then exit 1; fi
validate_timezone Etc/UTC
if validate_timezone ../etc/passwd; then exit 1; fi
validate_domain erp.business.example
if validate_domain 'bad host.example'; then exit 1; fi
validate_backup_path /var/backups/basm
if validate_backup_path '../relative'; then exit 1; fi
if validate_backup_path /var/backups/../tmp; then exit 1; fi

export LOCAL_BASM_ROOT="$TEST_DIR/stack"
PRODUCTION_BASM_ROOT="$TEST_DIR/production"
CONFIG_DIR="$TEST_DIR/config"
OUTPUT_DIR="$TEST_DIR/output"
BASM_ENV_FILE="$CONFIG_DIR/local.env"
mkdir -p "$CONFIG_DIR" "$OUTPUT_DIR" "$LOCAL_BASM_ROOT/config" "$PRODUCTION_BASM_ROOT/config"
printf 'COMPANY_NAME="Production sentinel"\n' > "$PRODUCTION_BASM_ROOT/config/basm.env"
port_in_use() { return 1; }

for address in 127.0.0.1 192.168.1.50; do
  previous_nextcloud_password="${NEXTCLOUD_ADMIN_PASSWORD:-}"
  if [[ "$address" == 127.0.0.1 ]]; then
    run_wizard < <(printf 'local\n\n\n\n\n\n\n2 6\n\nA\n')
  else
    run_wizard < <(printf 'local\n%s\n\n\n\n\n\n2 6\n\nA\n' "$address")
  fi
  for variable in DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD; do
    [[ "${!variable}" =~ ^[A-Za-z0-9]{32}$ ]]
    [[ "${!variable}" =~ [A-Z] && "${!variable}" =~ [a-z] && "${!variable}" =~ [0-9] ]]
  done
  if [[ -n "$previous_nextcloud_password" ]]; then
    [[ "$NEXTCLOUD_ADMIN_PASSWORD" == "$previous_nextcloud_password" ]]
  fi
  render_stack
  [[ "$(stat -c '%a' "$BASM_ENV_FILE")" == 600 ]]
  grep -Fq 'image: frappe/erpnext:v16' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'NEXTCLOUD_ADMIN_PASSWORD:' "$BASM_ROOT/docker-compose.yml"
  grep -Fq '"127.0.0.1:2525:25"' "$BASM_ROOT/docker-compose.yml"
  if grep -Fq 'postal-' "$BASM_ROOT/docker-compose.yml"; then exit 1; fi
  if grep -Eq 'restic-backup:|db-backup:' "$BASM_ROOT/docker-compose.yml"; then exit 1; fi
  ! grep -Fq "$DB_ROOT_PASSWORD" "$BASM_ROOT/docker-compose.yml"
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ENV_FILE" config -q
  fi
  [[ "$BIND_ADDRESS" == "$address" ]]
  [[ "$BASM_ROOT" == "$LOCAL_BASM_ROOT" ]]
  [[ "$BACKUP_LOCATION" == "$LOCAL_BASM_ROOT/backups" ]]
  [[ "$(< "$PRODUCTION_BASM_ROOT/config/basm.env")" == 'COMPANY_NAME="Production sentinel"' ]]
  grep -Fq "\"$address:18080:80\"" "$BASM_ROOT/docker-compose.yml"
  grep -Fq "\"$address:18443:443\"" "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'container_name: basm-local-traefik' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'address: ":80"' "$BASM_ROOT/config/traefik-static.yml"
  grep -Fq -- '--configfile=/etc/traefik/static.yml' "$BASM_ROOT/docker-compose.yml"
  grep -Fq '/config/traefik.yml:/etc/traefik/dynamic.yml:ro' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'Host(`127.0.0.1`)' "$BASM_ROOT/config/traefik.yml"
  mail_redirect="http://mx.${PRIMARY_DOMAIN}/\$1"
  jq -e --arg redirect "$mail_redirect" '.http.routers.mail.service == "noop@internal" and
    .http.routers.mail.middlewares == ["mail-canonical"] and
    .http.middlewares["mail-canonical"].redirectRegex.replacement == $redirect' \
    "$BASM_ROOT/config/traefik.yml" >/dev/null
  if grep -Eq 'acme|letsencrypt|certResolver|websecure|\$\{' "$BASM_ROOT/config/traefik.yml"; then exit 1; fi
  if [[ "$address" == 127.0.0.1 ]]; then
    [[ "$ERP_URL" == erp.localhost ]]
  else
    [[ "$ERP_URL" == erp.basm.test ]]
  fi
  for module_name in lamp uptime-kuma; do
    source "$ROOT_DIR/modules/$module_name.sh"
    module_install
  done
  grep -Fq "\"$address:18081:80\"" "$BASM_ROOT/modules/lamp/docker-compose.yml"
  grep -Fq "\"$address:18301:3001\"" "$BASM_ROOT/modules/uptime-kuma/docker-compose.yml"
  grep -Fqx '    image: louislam/uptime-kuma:2' "$BASM_ROOT/modules/uptime-kuma/docker-compose.yml"
  write_summary
  grep -Fq "http://$ERP_URL:18080" "$OUTPUT_DIR/local-installation-summary.txt"
done

unset BIND_ADDRESS BASM_CONTAINER_PREFIX
DEPLOYMENT_MODE=production
set_port_defaults standard
render_stack
grep -Fq '"0.0.0.0:80:80"' "$BASM_ROOT/docker-compose.yml"
grep -Fq 'container_name: basm-traefik' "$BASM_ROOT/docker-compose.yml"
grep -Fqx 'certificatesResolvers:' "$BASM_ROOT/config/traefik-static.yml"
grep -Fq 'tlsChallenge: {}' "$BASM_ROOT/config/traefik-static.yml"
mkdir -p "$BASM_ROOT/data/traefik"
printf 'abcdefghijklmnopqrstuvwxyz12\n' > "$BASM_ROOT/data/traefik/desec-token"
chmod 600 "$BASM_ROOT/data/traefik/desec-token"
render_stack
grep -Fq 'dnsChallenge:' "$BASM_ROOT/config/traefik-static.yml"
grep -Fq 'provider: desec' "$BASM_ROOT/config/traefik-static.yml"
if grep -Fq 'tlsChallenge:' "$BASM_ROOT/config/traefik-static.yml"; then exit 1; fi
rm "$BASM_ROOT/data/traefik/desec-token"
printf '198.51.100.10\n' > "$BASM_ROOT/config/traefik-edge-ip"
render_stack
grep -Fq 'trustedIPs: ["198.51.100.10/32"]' "$BASM_ROOT/config/traefik-static.yml"
printf 'not-an-address\n' > "$BASM_ROOT/config/traefik-edge-ip"
if (render_stack) >"$TEST_DIR/edge-error" 2>&1; then exit 1; fi
rm "$BASM_ROOT/config/traefik-edge-ip"
source "$ROOT_DIR/modules/lamp.sh"
MANAGEMENT_BIND_ADDRESS=127.0.0.1
module_install
grep -Fq '"127.0.0.1:8080:80"' "$BASM_ROOT/modules/lamp/docker-compose.yml"
select_deployment < <(printf 'not-a-domain\nbusiness.example\n')
[[ "$LOCAL_MODE" == false ]]
[[ "$PRIMARY_DOMAIN" == business.example ]]
[[ "$BASM_ENV_FILE" == "$PRODUCTION_BASM_ROOT/config/basm.env" ]]
[[ "$BASM_ROOT" == "$PRODUCTION_BASM_ROOT" ]]
[[ "$COMPANY_NAME" == 'Production sentinel' ]]

run_wizard < <(printf 'local\n\n\n\n\n\n\n2 3 6\ncustom\n19080\n19443\n12525\n12465\n12993\n18082\n19081\n51825\n19301\n22115\n22116\n22117\nA\n')
[[ "$PORT_PROFILE" == custom ]]
unset HTTP_PORT HTTPS_PORT LAMP_PORT UPTIME_KUMA_PORT WIREGUARD_PORT
set -a
source "$BASM_ENV_FILE"
set +a
render_stack
grep -Fq '"127.0.0.1:19080:80"' "$BASM_ROOT/docker-compose.yml"
grep -Fq '"127.0.0.1:19443:443"' "$BASM_ROOT/docker-compose.yml"
for module_name in lamp wireguard uptime-kuma; do
  source "$ROOT_DIR/modules/$module_name.sh"
  module_install
done
grep -Fq '"127.0.0.1:19081:80"' "$BASM_ROOT/modules/lamp/docker-compose.yml"
grep -Fq '"127.0.0.1:19301:3001"' "$BASM_ROOT/modules/uptime-kuma/docker-compose.yml"
grep -Fq 'ListenPort = 51825' "$BASM_ROOT/modules/wireguard/config.conf"
write_summary
grep -Fq 'http://erp.localhost:19080' "$OUTPUT_DIR/local-installation-summary.txt"
grep -Fq 'LAMP: http://127.0.0.1:19081' "$OUTPUT_DIR/local-installation-summary.txt"
if grep -Eq 'certificatesResolvers|acme' "$BASM_ROOT/config/traefik-static.yml"; then exit 1; fi

run_wizard < <(printf 'business.example\n\nadmin@business.dk\n\n\n\n\n\n\nnon-static\nshort\nabcdefghijklmnopqrstuvwxyz12\n2 3 6\nstandard\nA\n')
grep -Fqx 'IP_MODE="non-static"' "$BASM_ENV_FILE"
grep -Fqx 'DESEC_TOKEN="abcdefghijklmnopqrstuvwxyz12"' "$BASM_ENV_FILE"
(
  BASM_CRON_DIR="$TEST_DIR/cron.d"
  systemctl() { :; }
  curl() { if [[ "$*" == *api.ipify.org* ]]; then printf '203.0.113.7'; else { cat; printf '%s\n' "$*"; } > "$TEST_DIR/curl-request"; fi; }
  export -f curl
  export TEST_DIR
  install_ddns_updater
  grep -Fq "17 */4 * * * root /bin/bash \"$BASM_ROOT/maintenance/ddns-update.sh\" \"$BASM_ROOT\"" "$(ddns_cron_file "$BASM_ROOT")"
  [[ "$(< "$BASM_ROOT/config/last-public-ip")" == 203.0.113.7 ]]
  grep -Fq 'Authorization: Token abcdefghijklmnopqrstuvwxyz12' "$TEST_DIR/curl-request"
  grep -Fq 'hostname=business.example,cloud.business.example,erp.business.example,mail.business.example,mx.business.example&myipv4=203.0.113.7' "$TEST_DIR/curl-request"
  IP_MODE=static install_ddns_updater
  [[ ! -e "$(ddns_cron_file "$BASM_ROOT")" && ! -e "$BASM_ROOT/maintenance/ddns-update.sh" ]]
)
mkdir -p "$BASM_ROOT/config"
render_stack
write_summary
[[ "$HTTP_PORT" == 80 && "$HTTPS_PORT" == 443 && "$LAMP_PORT" == 8080 && "$UPTIME_KUMA_PORT" == 3001 && "$WIREGUARD_PORT" == 51820 ]]
grep -Fq '"0.0.0.0:80:80"' "$BASM_ROOT/docker-compose.yml"
grep -Fq 'https://erp.business.example:443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fqx 'certificatesResolvers:' "$BASM_ROOT/config/traefik-static.yml"
if grep -Eq '^(entryPoints|certificatesResolvers):' "$BASM_ROOT/config/traefik.yml"; then exit 1; fi
port_in_use() { return 1; }
configure_ports < <(printf 'custom\n19080\n19443\n12525\n12465\n12993\n18082\n19081\n51825\n19301\n22115\n22116\n22117\n')
render_stack
write_summary
grep -Fq 'https://erp.business.example:19443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq '"0.0.0.0:19443:443"' "$BASM_ROOT/docker-compose.yml"
(
  HTTP_PORT="$LAMP_PORT"
  BASM_MODULES=basm
  if (run_module_install lamp); then exit 1; fi
)

(
  BASM_ROOT="$TEST_DIR/local-fluxer"
  DEPLOYMENT_MODE=local
  BIND_ADDRESS=127.0.0.1
  BASM_CONTAINER_PREFIX=basm-local
  PRIMARY_DOMAIN=localhost
  FLUXER_DOMAIN=chat.localhost
  HTTP_PORT=18080
  HTTPS_PORT=18443
  source "$ROOT_DIR/modules/fluxer.sh"
  if (module_install); then exit 1; fi
  [[ ! -e "$BASM_ROOT/modules/fluxer" ]]
)

printf 'Local mode tests passed.\n'