#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/modules"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/modules/core.sh"

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
configure_ports < <(printf 'custom\n9000\n9443\n2526\n9001\n9301\n51822\n')
[[ "$HTTP_PORT" == 9000 && "$HTTPS_PORT" == 9443 && "$SMTP_PORT" == 2526 && "$LAMP_PORT" == 9001 && "$UPTIME_KUMA_PORT" == 9301 && "$WIREGUARD_PORT" == 51822 ]]
for port in 0 65536 080 abc; do
  if validate_port "$port"; then exit 1; fi
done

# A base install plans all future module ports and rejects future TCP collisions.
BASM_MODULES=basm
configure_ports < <(printf 'custom\n9000\n9443\n2526\n9000\n51822\n9301\ncustom\n9000\n9443\n2526\n9001\n51822\n9301\n')
[[ "$BASM_MODULES" == basm ]]
[[ "$LAMP_PORT" == 9001 && "$WIREGUARD_PORT" == 51822 && "$UPTIME_KUMA_PORT" == 9301 ]]
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
  if [[ "$address" == 127.0.0.1 ]]; then
    run_wizard < <(printf 'local\n\n\n\n\n\n\n2 6\n\n')
  else
    run_wizard < <(printf 'local\n%s\n\n\n\n\n\n2 6\n\n' "$address")
  fi
  render_stack
  render_postal_config
  [[ "$(stat -c '%a' "$BASM_ENV_FILE")" == 600 ]]
  [[ "$(stat -c '%a' "$BASM_ROOT/config/postal/postal.yml")" == 640 ]]
  [[ "$(stat -c '%a' "$BASM_ROOT/config/postal/signing.key")" == 640 ]]
  grep -Fq 'image: frappe/erpnext:v16.52.1' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'NEXTCLOUD_ADMIN_PASSWORD:' "$BASM_ROOT/docker-compose.yml"
  grep -Fq '"127.0.0.1:2525:25"' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'restic backup /source/erpnext' "$BASM_ROOT/docker-compose.yml"
  grep -Fq 'mariadb-dump --skip-ssl' "$BASM_ROOT/docker-compose.yml"
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
source "$ROOT_DIR/modules/lamp.sh"
module_install
grep -Fq '"0.0.0.0:8080:80"' "$BASM_ROOT/modules/lamp/docker-compose.yml"
select_deployment < <(printf 'not-a-domain\nbusiness.example\n')
[[ "$LOCAL_MODE" == false ]]
[[ "$PRIMARY_DOMAIN" == business.example ]]
[[ "$BASM_ENV_FILE" == "$PRODUCTION_BASM_ROOT/config/basm.env" ]]
[[ "$BASM_ROOT" == "$PRODUCTION_BASM_ROOT" ]]
[[ "$COMPANY_NAME" == 'Production sentinel' ]]

run_wizard < <(printf 'local\n\n\n\n\n\n\n2 3 6\ncustom\n19080\n19443\n12525\n19081\n51825\n19301\n')
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

run_wizard < <(printf 'business.example\n\nadmin@business.dk\n\n\n\n\n\n\n2 3 6\nstandard\n')
mkdir -p "$BASM_ROOT/config"
render_stack
write_summary
[[ "$HTTP_PORT" == 80 && "$HTTPS_PORT" == 443 && "$LAMP_PORT" == 8080 && "$UPTIME_KUMA_PORT" == 3001 && "$WIREGUARD_PORT" == 51820 ]]
grep -Fq '"0.0.0.0:80:80"' "$BASM_ROOT/docker-compose.yml"
grep -Fq 'https://erp.business.example:443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fqx 'certificatesResolvers:' "$BASM_ROOT/config/traefik-static.yml"
if grep -Eq '^(entryPoints|certificatesResolvers):' "$BASM_ROOT/config/traefik.yml"; then exit 1; fi
port_in_use() { return 1; }
configure_ports < <(printf 'custom\n19080\n19443\n12525\n19081\n51825\n19301\n')
render_stack
write_summary
grep -Fq 'https://erp.business.example:19443' "$OUTPUT_DIR/installation-summary.txt"
grep -Fq '"0.0.0.0:19443:443"' "$BASM_ROOT/docker-compose.yml"
(
  HTTP_PORT="$LAMP_PORT"
  BASM_MODULES=basm
  if (run_module_install lamp); then exit 1; fi
)
printf 'Local mode tests passed.\n'