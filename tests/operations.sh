#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BASM_ROOT="$TEMP/live"
BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
BASM_CONTAINER_PREFIX=basm-test
BASM_MODULES='basm lamp uptime-kuma rustdesk wireguard'
DEPLOYMENT_MODE=local
BACKUP_LOCATION="$BASM_ROOT/backups"
RESTIC_PASSWORD=test-only-repository-password
CALLS="$TEMP/calls"
mkdir -p "$BASM_ROOT/config" "$BASM_ROOT/data" "$BASM_ROOT/logs"
BASM_CRON_DIR="$TEMP/cron"
install_runtime
printf 'test configuration\n' > "$BASM_ENV_FILE"
printf 'original compose\n' > "$BASM_ROOT/docker-compose.yml"
for module in lamp uptime-kuma rustdesk wireguard; do
  mkdir -p "$BASM_ROOT/modules/$module/data"
  printf '%s-data\n' "$module" > "$BASM_ROOT/modules/$module/data/important"
  [[ "$module" == wireguard ]] || printf 'test stack\n' > "$BASM_ROOT/modules/$module/docker-compose.yml"
done
FAIL_STOP=false FAIL_BACKUP=false FAIL_START=false FAIL_DUMP=false
stack_command() {
  local file="$1"
  shift
  printf '%s %s\n' "${file#"$BASM_ROOT"/}" "$*" >> "$CALLS"
  local marker="$TEMP/$(basename "$(dirname "$file")").stopped"
  case "$*" in
    'config --format json')
      printf '{"services":{"app":{"image":"example/app:1","restart":"unless-stopped"}}}\n' ;;
    'ps --status running --services')
      [[ -f "$marker" ]] || printf 'app\n' ;;
    'ps --all -q '*) printf 'container-id\n' ;;
    'ps --status running -q') [[ -f "$marker" ]] || printf 'container-id\n' ;;
    'stop --timeout 120'*)
      [[ "$FAIL_STOP" == false ]] || return 1
      touch "$marker" ;;
    'start --wait --wait-timeout 900 '*)
      [[ "$FAIL_START" == false ]] || return 1
      rm -f "$marker" ;;
    'exec -T '*)
      [[ "$FAIL_DUMP" == false ]] || return 1
      printf 'database dump\n' ;;
    *) printf 'Unexpected stack command: %s\n' "$*" >&2; return 1 ;;
  esac
}
basm_stack() { stack_command "$BASM_ROOT/docker-compose.yml" "$@"; }
docker() {
  case "$*" in
    'inspect '*) printf 'image-id\n' ;;
    'image inspect '*) printf '["example/app@sha256:%064d"]\n' 0 ;;
    *) return 1 ;;
  esac
}
restic() {
  [[ "$1" != backup || "$FAIL_BACKUP" == false ]] || return 1
  command "${RESTIC_BIN:-restic}" "$@"
}
expect_failure() {
  local result
  set +e
  ("$@") > "$TEMP/expected-failure.log" 2>&1
  result=$?
  set -e
  if (( result == 0 )); then printf 'Expected failure: %s\n' "$*" >&2; exit 1; fi
}
(
  BASM_ENV_FILE="$TEMP/wrong-root.env"
  printf 'BASM_ROOT="/wrong-root"\n' > "$BASM_ENV_FILE"
  expect_failure load_deployment_env
)
initialize_repository
backup_deployment
snapshot="$(restic_command snapshots --json | jq -r 'last | .short_id')"
restore_deployment "$snapshot" "$TEMP/staged"
for module in lamp uptime-kuma rustdesk wireguard; do
  cmp "$BASM_ROOT/modules/$module/data/important" "$TEMP/staged$BASM_ROOT/modules/$module/data/important"
done
[[ ! -e "$TEMP/staged$BACKUP_LOCATION" ]]
[[ -s "$TEMP/staged$BASM_ROOT/data/db-backups/erp-db.sql" ]]
[[ "$(stat -c %a "$TEMP/staged")" == 700 ]]
for path in / "$BASM_ROOT" "$BASM_ROOT/new" "$BACKUP_LOCATION/new" "$TEMP" "$TEMP/staged"; do
  expect_failure restore_deployment "$snapshot" "$path"
done
expect_failure restore_deployment latest "$TEMP/new"
for failure in FAIL_BACKUP FAIL_DUMP FAIL_STOP FAIL_START; do
  printf -v "$failure" true
  : > "$CALLS"
  expect_failure backup_deployment
  grep -Fq 'start --wait --wait-timeout 900 app' "$CALLS"
  printf -v "$failure" false
  rm -f "$TEMP/live.stopped" "$TEMP/lamp.stopped" "$TEMP/uptime-kuma.stopped" "$TEMP/rustdesk.stopped"
done
restic_command check --read-data
(
  printf 'services:\n  db-backup: {}\n  restic-backup: {}\n' > "$BASM_ROOT/docker-compose.yml"
  record_stack_images "$BASM_ROOT/docker-compose.yml" "$BASM_ROOT/config/images.json"
  record_stack_images "$BASM_ROOT/docker-compose.yml" "$BASM_ROOT/config/images.json"
  jq -e '.services["db-backup"].profiles == ["legacy-backup"] and
    .services["restic-backup"].profiles == ["legacy-backup"]' "$BASM_ROOT/config/images.json" >/dev/null
  printf 'original compose\n' > "$BASM_ROOT/docker-compose.yml"
)
(
  acquire_operation_lock
  expect_failure bash -c 'exec 8>"$1"; flock -n 8' _ "$BASM_ROOT/logs/update.lock"
)
(
  stack_command() {
    if [[ "$*" == *'config --format json' ]]; then
      printf '{"services":{"app":{"image":"app:1","restart":"unless-stopped","healthcheck":{"test":["CMD","true"]},"depends_on":{"init":{"condition":"service_completed_successfully"}}},"init":{"image":"app:1"}}}\n'
    else
      jq -nc --arg health "${TEST_HEALTH:-healthy}" --argjson exit "${TEST_EXIT:-0}" \
        '[{Service:"app",State:"running",Health:$health},{Service:"init",State:"exited",ExitCode:$exit}]'
    fi
  }
  check_stack "$BASM_ROOT/docker-compose.yml"
  TEST_HEALTH=unhealthy expect_failure check_stack "$BASM_ROOT/docker-compose.yml"
  TEST_EXIT=1 expect_failure check_stack "$BASM_ROOT/docker-compose.yml"
)
(
  source "$ROOT_DIR/modules/releases.sh"
  docker() {
    if [[ "${*: -1}" == nextcloud-image ]]; then
      printf '["NEXTCLOUD_VERSION=33.0.10"]\n'
    else
      printf '["MARIADB_VERSION=1:11.8.6+maria~ubu2404"]\n'
    fi
  }
  [[ "$(image_version nextcloud nextcloud-image)" == 33 ]]
  [[ "$(image_version erp-db mariadb-image)" == 11.8 ]]
  image_version() {
    case "$1" in nextcloud) printf '%s\n' "${NEXT_VERSION:-33}" ;; *) printf '%s\n' "${DB_VERSION:-11.8}" ;; esac
  }
  old='{"nextcloud":"33","erp-db":"11.8","nextcloud-db":"11.8","postal-db":"11.8","erpnext-backend":"16"}'
  candidate='{"services":{"nextcloud":{"image":"nextcloud:33-apache"},"erp-db":{"image":"mariadb:11.8"},"nextcloud-db":{"image":"mariadb:11.8"},"postal-db":{"image":"mariadb:11.8"},"erpnext-backend":{"image":"frappe/erpnext:v16"}}}'
  validate_update_versions "$old" "$candidate" "$TEMP"
  NEXT_VERSION=35 expect_failure validate_update_versions "$old" "$candidate" "$TEMP"
  NEXT_VERSION=32 expect_failure validate_update_versions "$old" "$candidate" "$TEMP"
  DB_VERSION=12.0 expect_failure validate_update_versions "$old" "$candidate" "$TEMP"
  DB_VERSION=10.11 expect_failure validate_update_versions "$old" "$candidate" "$TEMP"
  mkdir "$TEMP/migrations"
  for service in erp-db nextcloud-db postal-db; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEMP/migrations/$service-11.8-12.0.sh"
  done
  DB_VERSION=12.0 validate_update_versions "$old" "$candidate" "$TEMP"
  [[ ${#MIGRATIONS[@]} == 3 ]]
  for hour in 00 01 02 03 04 05; do scheduled_update_window "$hour"; done
  for hour in 06 12 23 invalid; do expect_failure scheduled_update_window "$hour"; done
)
(
  BASM_MODULES=basm
  installed_versions() { printf '{}\n'; }
  validate_update_versions() { :; }
  render_stack() {
    printf 'candidate compose\n' > "$BASM_RENDER_DIR/docker-compose.yml"
    printf '{}\n' > "$BASM_RENDER_DIR/config/traefik.yml"
    printf '{}\n' > "$BASM_RENDER_DIR/config/traefik-static.yml"
    mkdir -p "$BASM_RENDER_DIR/home"
    printf 'start page\n' > "$BASM_RENDER_DIR/home/index.html"
    printf 'mascot\n' > "$BASM_RENDER_DIR/home/mascot.png"
  }
  render_postal_config() {
    mkdir -p "$BASM_RENDER_DIR/config/postal" "$BASM_ROOT/config/postal"
    printf 'test postal config\n' > "$BASM_RENDER_DIR/config/postal/postal.yml"
  }
  basm_compose() {
    printf 'compose %s\n' "$*" >> "$CALLS"
    case "$*" in
      *'config --format json') printf '{"services":{"app":{"image":"example/app:1"}}}\n' ;;
      *'pull --quiet') [[ "${FAIL_PULL:-false}" == false ]] ;;
    esac
  }
  backup_deployment() { printf 'backup\n' >> "$CALLS"; [[ "$FAIL_BACKUP" == false ]]; }
  module_compose_files() { :; }
  start_stacks() { printf 'start\n' >> "$CALLS"; [[ "$FAIL_START" == false ]]; }
  check_stack() { :; }
  check_deployment() { [[ "${FAIL_HEALTH:-false}" == false ]]; }
  install_runtime() { :; }
  FAIL_PULL=true expect_failure update_deployment "$ROOT_DIR"
  FAIL_BACKUP=true expect_failure update_deployment "$ROOT_DIR"
  [[ ! -e "$BASM_ROOT/config/update-in-progress" ]]
  grep -Fxq 'original compose' "$BASM_ROOT/docker-compose.yml"
  : > "$CALLS"
  update_deployment "$ROOT_DIR"
  [[ ! -e "$BASM_ROOT/config/update-in-progress" ]]
  [[ "$(grep -n '^backup$' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^start$' "$CALLS" | cut -d: -f1)" ]]
  FAIL_START=true expect_failure update_deployment "$ROOT_DIR"
  [[ -f "$BASM_ROOT/config/update-in-progress" ]]
  expect_failure update_deployment "$ROOT_DIR"
  rm "$BASM_ROOT/config/update-in-progress"
  FAIL_HEALTH=true expect_failure update_deployment "$ROOT_DIR"
  [[ -f "$BASM_ROOT/config/update-in-progress" ]]
  rm "$BASM_ROOT/config/update-in-progress"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TEMP/failed-migration.sh"
  validate_update_versions() { MIGRATIONS=("$TEMP/failed-migration.sh"); }
  : > "$CALLS"
  expect_failure update_deployment "$ROOT_DIR"
  [[ -f "$BASM_ROOT/config/update-in-progress" ]]
  if grep -Fxq start "$CALLS"; then exit 1; fi
  rm "$BASM_ROOT/config/update-in-progress"
)
(
  updater="$TEMP/updater"
  mkdir -p "$updater/modules"
  cp "$ROOT_DIR/update.sh" "$updater/update.sh"
  printf 'source %q\n' "$ROOT_DIR/modules/core.sh" > "$updater/modules/core.sh"
  cat >> "$updater/modules/core.sh" <<'EOF'
require_root() { :; }
load_deployment_env() { :; }
acquire_operation_lock() { :; }
install_operation_trap() { :; }
date() {
  if [[ "$1" == +%H ]]; then printf '%s\n' "$TEST_HOUR"; else command date "$@"; fi
}
update_deployment() { printf 'update %s\n' "$BASM_ROOT" >> "$TEST_UPDATE_LOG"; }
EOF
  export TEST_UPDATE_LOG="$TEMP/update-entry.log" TEST_HOUR=03
  bash "$updater/update.sh" --root "$BASM_ROOT"
  bash "$updater/update.sh" --scheduled "$BASM_ROOT"
  [[ "$(wc -l < "$TEST_UPDATE_LOG")" == 2 ]]
  TEST_HOUR=12 expect_failure bash "$updater/update.sh" --scheduled "$BASM_ROOT"
  [[ "$(wc -l < "$TEST_UPDATE_LOG")" == 2 ]]
  touch "$BASM_ROOT/config/disable-auto-updates"
  bash "$updater/update.sh" --scheduled "$BASM_ROOT"
  [[ "$(wc -l < "$TEST_UPDATE_LOG")" == 2 ]]
  rm "$BASM_ROOT/config/disable-auto-updates"
)
(
  BASM_MODULES=basm BIND_ADDRESS=127.0.0.1 HTTPS_PORT=18443 HTTP_PORT=18080 PRIMARY_DOMAIN=localhost
  ERP_URL=erp.localhost MAIL_URL=mail.localhost CLOUD_URL=cloud.localhost
  check_stack() { :; }
  curl() { :; }
  restic_command() {
    jq -nc --arg root "$BASM_ROOT" --arg time "$(date -d "${BACKUP_HOURS:-35} hours ago" -Is)" '[{time:$time,paths:[$root]}]'
  }
  df() { printf 'Use%%\n%s%%\n' "${DISK_PERCENT:-89}"; }
  check_deployment
  BACKUP_HOURS=36 expect_failure check_deployment
  BACKUP_HOURS=-1 expect_failure check_deployment
  DISK_PERCENT=90 expect_failure check_deployment
)
(
  logger() { :; }
  curl() { cat > "$TEMP/webhook-config"; printf '%s\n' "$*" > "$TEMP/webhook-args"; }
  printf 'https://alerts.example.test/hook\n' > "$BASM_ROOT/config/alert-webhook"
  notify_failure 'Test operation failed'
  grep -Fq 'Test operation failed' "$BASM_ROOT/logs/last-failure"
  grep -Fq 'url = "https://alerts.example.test/hook"' "$TEMP/webhook-config"
  grep -Fq '"message":"Test operation failed"' "$TEMP/webhook-args"
  printf 'http://unsafe.example.test/hook\n' > "$BASM_ROOT/config/alert-webhook"
  expect_failure notify_failure 'Test operation failed'
)
printf 'Consistent backup, real encrypted restore, update gates, locks, health and webhook tests passed.\n'
