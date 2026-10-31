#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/modules"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/modules/core.sh"

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

set_port_defaults standard
BASM_MODULES='basm fluxer wireguard'
FLUXER_LIVEKIT_UDP_PORT=51820
if validate_port_plan; then exit 1; fi
FLUXER_LIVEKIT_UDP_PORT=7882
FLUXER_LIVEKIT_TCP_PORT=80
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
    run_wizard < <(printf 'local\n\n\n\n\n\n\n2 6\n\n')
  else
    run_wizard < <(printf 'local\n%s\n\n\n\n\n\n2 6\n\n' "$address")
  fi
  for variable in DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD POSTAL_DB_PASSWORD POSTAL_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD; do
    [[ "${!variable}" =~ ^[A-Za-z0-9]{32}$ ]]
    [[ "${!variable}" =~ [A-Z] && "${!variable}" =~ [a-z] && "${!variable}" =~ [0-9] ]]
  done
  [[ "$POSTAL_RAILS_SECRET" =~ ^[0-9a-f]{64}$ ]]
  if [[ -n "$previous_nextcloud_password" ]]; then
    [[ "$NEXTCLOUD_ADMIN_PASSWORD" == "$previous_nextcloud_password" ]]
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

run_wizard < <(printf 'business.example\n\nadmin@business.dk\n\n\n\n\n\n\nnon-static\nshort\nabcdefghijklmnopqrstuvwxyz12\n2 3 6\nstandard\n')
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

FLUXER_ROOT="$TEST_DIR/fluxer"
FLUXER_BUNDLE_DIR="$TEST_DIR/fluxer-bundle"
mkdir -p "$FLUXER_BUNDLE_DIR" "$FLUXER_ROOT/config"
cat > "$FLUXER_BUNDLE_DIR/.env.example" <<'EOF'
FLUXER_SETTINGS_LOADED=true
FLUXER_DOMAIN=
FLUXER_SETUP_TOKEN=
POSTGRES_PASSWORD=
MEILI_MASTER_KEY=
FLUXER_S3_SECRET_KEY=
LIVEKIT_API_SECRET=
FLUXER_SUDO_MODE_SECRET=
FLUXER_CONNECTION_INITIATION_SECRET=
FLUXER_PROFILE_PSEUDONYM_SECRET=
FLUXER_GATEWAY_RPC_AUTH_TOKEN=
FLUXER_ERLANG_COOKIE=
FLUXER_MEDIA_PROXY_SECRET_KEY=
FLUXER_ADMIN_SECRET_KEY_BASE=
FLUXER_ADMIN_OAUTH_CLIENT_SECRET=
FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64=
FLUXER_ACTIVITYPUB_SIGNING_KEY_BASE64=
FLUXER_VAPID_PUBLIC_KEY=
FLUXER_VAPID_PRIVATE_KEY=
FLUXER_LIVEKIT_TCP_PORT=7881
FLUXER_LIVEKIT_UDP_PORT=7882
EOF
cat > "$FLUXER_BUNDLE_DIR/docker-compose.yml" <<'EOF'
services:
  release-check:
    image: fluxer-test:v1
  edge:
    image: caddy:2
    ports:
      - "80:80"
    networks:
      - fluxer
  livekit:
    image: livekit/livekit-server
    ports:
      - "7881:7881"
      - "7882:7882/udp"
    networks:
      - fluxer
  postgres:
    image: postgres:16-alpine
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
    networks:
      - fluxer
networks:
  fluxer:
volumes:
  edge-data:
  edge-config:
  postgres-data:
  valkey-data:
  nats-data:
  meilisearch-data:
  seaweedfs-data:
  media-proxy-tmp:
EOF
printf 'services: {}\n' > "$FLUXER_BUNDLE_DIR/docker-compose.proxy.yml"
tar -czf "$TEST_DIR/fluxer-compose.tar.gz" -C "$FLUXER_BUNDLE_DIR" .
(
  BASM_ROOT="$FLUXER_ROOT"
  DEPLOYMENT_MODE=local
  BIND_ADDRESS=127.0.0.1
  BASM_CONTAINER_PREFIX=basm-local
  PRIMARY_DOMAIN=localhost
  FLUXER_DOMAIN=chat.localhost
  HTTP_PORT=18080
  HTTPS_PORT=18443
  FLUXER_LIVEKIT_TCP_PORT=17881
  FLUXER_LIVEKIT_UDP_PORT=17882
  ERP_URL=erp.localhost
  MAIL_URL=mail.localhost
  CLOUD_URL=cloud.localhost
  FLUXER_COMPOSE_BUNDLE="$TEST_DIR/fluxer-compose.tar.gz"
  render_stack
  grep -Fq 'Host(`chat.localhost`)' "$BASM_ROOT/config/traefik.yml"
  source "$ROOT_DIR/modules/fluxer.sh"
  module_install
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$BASM_ROOT/modules/fluxer/.env" \
      -f "$BASM_ROOT/modules/fluxer/docker-compose.yml" \
      -f "$BASM_ROOT/modules/fluxer/docker-compose.proxy.yml" \
      -f "$BASM_ROOT/modules/fluxer/docker-compose.basm.yml" config -q
  fi
  setup_token="$(sed -n 's/^FLUXER_SETUP_TOKEN=//p' "$BASM_ROOT/modules/fluxer/.env")"
  [[ "$setup_token" =~ ^[a-f0-9]{64}$ ]]
  grep -Fqx 'FLUXER_PUBLIC_ORIGIN=http://chat.localhost:18080' "$BASM_ROOT/modules/fluxer/.env"
  grep -Fqx 'FLUXER_LIVEKIT_USE_EXTERNAL_IP=false' "$BASM_ROOT/modules/fluxer/.env"
  grep -Fq 'device: ${BASM_ROOT}/data/fluxer/postgres-data' "$BASM_ROOT/modules/fluxer/docker-compose.basm.yml"
  grep -Fq 'fluxer-db-backups:/backups' "$BASM_ROOT/modules/fluxer/docker-compose.basm.yml"
  [[ "$(stat -c '%a' "$BASM_ROOT/modules/fluxer/.env")" == 600 ]]
  module_install
  [[ "$(sed -n 's/^FLUXER_SETUP_TOKEN=//p' "$BASM_ROOT/modules/fluxer/.env")" == "$setup_token" ]]
  printf 'services:\n  release-check:\n    image: fluxer-test:v2\n' > "$FLUXER_BUNDLE_DIR/docker-compose.yml"
  tar -czf "$TEST_DIR/fluxer-compose.tar.gz" -C "$FLUXER_BUNDLE_DIR" .
  module_update "$BASM_ROOT/modules/fluxer"
  grep -Fq 'image: fluxer-test:v2' "$BASM_ROOT/modules/fluxer/docker-compose.yml"
  [[ "$(sed -n 's/^FLUXER_SETUP_TOKEN=//p' "$BASM_ROOT/modules/fluxer/.env")" == "$setup_token" ]]
  BASM_MODULES='basm fluxer'
  DEPLOYMENT_MODE=production
  BIND_ADDRESS=0.0.0.0
  PRIMARY_DOMAIN=business.example
  FLUXER_DOMAIN=chat.business.example
  IP_MODE=static
  COMPANY_NAME='Acme Ltd'
  ADMIN_EMAIL=ops@business.example
  ERP_URL=erp.business.example
  MAIL_URL=mail.business.example
  CLOUD_URL=cloud.business.example
  HTTPS_PORT=443
  HTTP_PORT=80
  TIMEZONE=Etc/UTC
  ERP_ADMIN_PASSWORD=erp-test
  NEXTCLOUD_ADMIN_USER=basm-admin
  NEXTCLOUD_ADMIN_PASSWORD=cloud-test
  POSTAL_ADMIN_PASSWORD=postal-test
  DB_ROOT_PASSWORD=db-root-test
  NEXTCLOUD_DB_PASSWORD=cloud-db-test
  POSTAL_DB_PASSWORD=postal-db-test
  POSTAL_RAILS_SECRET=postal-sign-test
  RESTIC_PASSWORD=restic-test
  BACKUP_LOCATION="$BASM_ROOT/backups"
  write_summary
  grep -Fq 'chat      A      PUBLIC_IP   (Fluxer: chat.business.example)' "$BASM_ROOT/handover/dns-records.txt"
  grep -Fq '"subname":"chat","type":"A","ttl":3600,"records":["$PUBLIC_IP"]' "$BASM_ROOT/handover/dns-records.txt"
  grep -Fq 'Address: https://chat.business.example:443' "$BASM_ROOT/handover/for-the-user.txt"
  grep -Fq "One-time setup token: $setup_token" "$BASM_ROOT/handover/for-the-user.txt"
  grep -Fq 'Fluxer: https://chat.business.example:443' "$OUTPUT_DIR/installation-summary.txt"
  grep -Fq 'Fluxer voice: 17881/tcp and 17882/udp' "$OUTPUT_DIR/installation-summary.txt"
)

printf 'Local mode tests passed.\n'