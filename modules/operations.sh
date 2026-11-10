#!/usr/bin/env bash

read_deployment_settings() {
  local settings key value
  settings="$(/usr/bin/python3 "$ROOT_DIR/templates/read-environment.py" "$BASM_ENV_FILE")" ||
    fail "Cannot parse BASM settings as data."
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    printf -v "$key" '%s' "$value"
    export "$key"
  done < <(jq -j 'to_entries[] | .key, "\u0000", .value, "\u0000"' <<< "$settings")
}

basm_stack() {
  local -a lock=()
  [[ ! -f "$BASM_ROOT/config/images.json" ]] || lock=(-f "$BASM_ROOT/config/images.json")
  basm_compose -f "$BASM_ROOT/docker-compose.yml" "${lock[@]}" --env-file "$BASM_ENV_FILE" "$@"
}

acquire_operation_lock() {
  [[ "${BASM_LOCK_ROOT:-}" != "$BASM_ROOT" ]] || return 0
  umask 077
  mkdir -p "$BASM_ROOT/logs" || fail "Cannot create operation log directory."
  exec 9> "$BASM_ROOT/logs/update.lock"
  if ! flock -w "${2:-0}" 9; then
    case "${1:-}" in
      check) log "Health check deferred while another operation is running."; exit 0 ;;
      examples) log "ERPNext examples deferred while another operation is running."; exit 0 ;;
    esac
    fail "Another BASM operation is already running."
  fi
  BASM_LOCK_ROOT="$BASM_ROOT"
}

notify_failure() {
  local message="$1" endpoint payload
  printf '%s: %s\n' "$(date -Is)" "$message" >&2
  mkdir -p "$BASM_ROOT/logs" || return 1
  printf '%s: %s\n' "$(date -Is)" "$message" > "$BASM_ROOT/logs/last-failure" || return 1
  logger -t basm -- "$message" || warn "Could not write BASM failure to the system journal."
  [[ -f "$BASM_ROOT/config/alert-webhook" ]] || return 0
  endpoint="$(< "$BASM_ROOT/config/alert-webhook")"
  [[ "$endpoint" =~ ^https://[^/@[:space:]]+(/[^[:space:]\"]*)?$ && "$endpoint" != *\\* ]] || {
    warn "Invalid alert-webhook: use one HTTPS URL without embedded user credentials."
    return 1
  }
  payload="$(jq -nc --arg host "$(hostname)" --arg deployment "$BASM_ROOT" --arg message "$message" \
    '{host:$host,deployment:$deployment,message:$message}')" || return 1
  printf 'url = "%s"\n' "$endpoint" |
    curl --config - --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=https' -H 'Content-Type: application/json' --data-binary "$payload" -o /dev/null || {
        warn "BASM webhook delivery failed; see local logs."
        return 1
      }
}

operation_exit() {
  local status="$1"
  trap - EXIT
  if (( status != 0 )); then
    notify_failure "${BASM_OPERATION:-Maintenance} failed (exit $status); inspect BASM logs." ||
      warn "Failure notification was not delivered."
  fi
  exit "$status"
}

install_operation_trap() {
  BASM_OPERATION="$1"
  trap 'operation_exit "$?"' EXIT
}

backup_cron_file() {
  printf '%s-backup' "$(update_cron_file "$1")"
}

check_cron_file() {
  printf '%s-check' "$(update_cron_file "$1")"
}

examples_cron_file() {
  printf '%s-examples' "$(update_cron_file "$1")"
}

seed_erp_examples() {
  case "${ERP_EXAMPLES:-no}" in
    no) log "ERPNext learning examples are disabled."; return 0 ;;
    yes) ;;
    *) fail "ERP_EXAMPLES must be yes or no." ;;
  esac
  [[ ! -e "$BASM_ROOT/config/update-in-progress" ]] ||
    fail "Resolve the interrupted ERPNext update before creating learning examples."
  basm_stack exec -T erpnext-backend ./env/bin/python - "$ERP_URL" \
    < "$ROOT_DIR/templates/erpnext-examples.py"
}

install_runtime() {
  local destination="$BASM_ROOT/maintenance" item
  install -d -m 700 "$destination" "$destination/modules" "$destination/templates" "$destination/bin" || return
  for item in "$ROOT_DIR"/modules/*.sh; do
    [[ "$item" != "$destination/modules/"* ]] || continue
    install -m 600 "$item" "$destination/modules/" || return
  done
  if [[ "$ROOT_DIR" != "$destination" ]]; then
    cp -a "$ROOT_DIR/templates/." "$destination/templates/" || return
    install -m 700 "$ROOT_DIR/bin/basm" "$destination/bin/basm" || return
    for item in update.sh recover.sh; do
      install -m 700 "$ROOT_DIR/$item" "$destination/$item" || return
    done
    install -m 600 "$ROOT_DIR/VERSION" "$destination/VERSION" || return
    install -d -m 755 "$destination/docs/images" || return
    install -m 644 "$ROOT_DIR/docs/images/mascot.png" "$destination/docs/images/mascot.png" || return
    if [[ -d "$ROOT_DIR/migrations" ]]; then
      cp -a "$ROOT_DIR/migrations" "$destination/" || return
    fi
  fi
  if [[ -z "${BASM_CRON_DIR:-}" ]]; then
    install -d /usr/local/bin || return
    ln -sfn "$destination/bin/basm" /usr/local/bin/basm || return
  fi
}

refresh_routes() (
  local stage
  stage="$(mktemp -d)" || return
  trap 'rm -rf "$stage"' EXIT
  mkdir "$stage/config" || return
  BASM_RENDER_DIR="$stage" render_stack || return
  install -m 600 "$stage/config/traefik.yml" "$BASM_ROOT/config/traefik.yml" || return
  install -m 600 "$stage/config/traefik-static.yml" "$BASM_ROOT/config/traefik-static.yml" || return
  install -d -m 755 "$BASM_ROOT/home" || return
  install -m 644 "$stage/home/index.html" "$stage/home/mascot.png" "$BASM_ROOT/home/"
)

install_auto_updates() (
  umask 077
  local maintenance_dir="$BASM_ROOT/maintenance" cron_file
  ensure_packages cron util-linux
  validate_backup_path "$BASM_ROOT" || fail "Deployment path is not safe for cron."
  install_runtime || fail "Cannot install BASM operator tools."
  mkdir -p "$BASM_ROOT/logs" "${BASM_CRON_DIR:-/etc/cron.d}" || return 1
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
  chmod 700 "$maintenance_dir/run-updates.sh" || return 1
  cron_file="$(update_cron_file "$BASM_ROOT")"
  cat > "$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 1 1,7 * root /bin/bash "$maintenance_dir/run-updates.sh"
EOF
  cat > "$(backup_cron_file "$BASM_ROOT")" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root /bin/bash "$maintenance_dir/bin/basm" --root "$BASM_ROOT" backup >> "$BASM_ROOT/logs/backup.log" 2>&1
EOF
  cat > "$(check_cron_file "$BASM_ROOT")" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
15 * * * * root /bin/bash "$maintenance_dir/bin/basm" --root "$BASM_ROOT" check >> "$BASM_ROOT/logs/check.log" 2>&1
EOF
  chmod 644 "$cron_file" "$(backup_cron_file "$BASM_ROOT")" "$(check_cron_file "$BASM_ROOT")" || return 1
  cron_file="$(examples_cron_file "$BASM_ROOT")"
  case "${ERP_EXAMPLES:-no}" in
    yes)
      cat > "$cron_file" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /bin/bash "$maintenance_dir/bin/basm" --root "$BASM_ROOT" examples >> "$BASM_ROOT/logs/erpnext-examples.log" 2>&1
EOF
      chmod 644 "$cron_file" || return 1 ;;
    no) rm -f "$cron_file" || return 1 ;;
    *) fail "ERP_EXAMPLES must be yes or no." ;;
  esac
  rm -f "$(fluxer_backup_cron_file "$BASM_ROOT")" "$maintenance_dir/run-fluxer-backup.sh" || return 1
  systemctl enable --now cron || fail "Cannot enable the maintenance scheduler."
  log "Automatic application updates scheduled for January 1 and July 1 at 03:00 (server time)."
  log "Consistent backups run daily at 02:00; health checks run hourly."
)

stack_command() {
  local file="$1"
  shift
  if [[ "$file" == "$BASM_ROOT/docker-compose.yml" ]]; then
    basm_stack "$@"
  else
    module_compose "$file" "$@"
  fi
}

deployment_stacks() {
  printf '%s\n' "$BASM_ROOT/docker-compose.yml"
  module_compose_files "$BASM_ROOT"
}

start_stacks() {
  local file
  while IFS= read -r file; do
    stack_command "$file" up -d --wait --wait-timeout 900 --remove-orphans || return
  done < <(deployment_stacks)
}

check_stack() {
  local file="$1" configuration states
  configuration="$(stack_command "$file" config --format json)" || return 1
  states="$(stack_command "$file" ps --all --format json)" || return 1
  jq -en --argjson config "$configuration" --argjson states "$(jq -s 'flatten' <<< "$states")" '
    [$config.services[].depends_on // {} | to_entries[] |
      select(.value.condition == "service_completed_successfully") | .key] as $completed |
    [$config.services | to_entries[] | select((.value.profiles // [] | length) == 0)] as $services |
    ($services | length) > 0 and all($services[];
      . as $service | [$states[] | select(.Service == $service.key)] as $actual |
      ($actual | length) > 0 and all($actual[];
        if ($completed | index($service.key)) != null then .State == "exited" and .ExitCode == 0
        else .State == "running" and
          (if $service.value.healthcheck != null and $service.value.healthcheck.disable != true
           then .Health == "healthy" else true end)
        end))' >/dev/null || {
      warn "Unhealthy or missing services in $file"
      return 1
    }
}

check_deployment() {
  local file snapshots newest used host scheme port endpoint address module timestamp age home_host
  [[ "${1:-}" == --updating || ! -e "$BASM_ROOT/config/update-in-progress" ]] || fail "An interrupted update needs repair."
  for module in lamp uptime-kuma rustdesk fluxer; do
    if module_selected "$module"; then
      [[ -f "$BASM_ROOT/modules/$module/docker-compose.yml" ]] || fail "Selected module is missing: $module"
    fi
  done
  if module_selected wireguard; then
    [[ -s "$BASM_ROOT/modules/wireguard/config.conf" ]] || fail "WireGuard configuration is missing."
  fi
  while IFS= read -r file; do check_stack "$file" || return 1; done < <(deployment_stacks)
  scheme=https; port="$HTTPS_PORT"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then scheme=http; port="$HTTP_PORT"; fi
  address="$BIND_ADDRESS"
  [[ "$address" != 0.0.0.0 ]] || address=127.0.0.1
  home_host="$PRIMARY_DOMAIN"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then home_host="home.$PRIMARY_DOMAIN"; fi
  for endpoint in "$home_host/" "$ERP_URL/api/method/ping" "$CLOUD_URL/status.php" "$MAILBOX_HOSTNAME/"; do
    host="${endpoint%%/*}"
    curl -fsS --connect-timeout 5 --max-time 20 --noproxy '*' \
      --resolve "$host:$port:$address" "$scheme://$host:$port/${endpoint#*/}" >/dev/null || {
        warn "Application endpoint failed: $host"
        return 1
      }
  done
  if module_selected fluxer; then
    host="$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' bridge)" || return
    curl -fsS --connect-timeout 5 --max-time 20 "http://$host:$FLUXER_PROXY_PORT/_health" >/dev/null || return
  fi
  snapshots="$(restic_command snapshots --host "$BASM_CONTAINER_PREFIX" --tag basm-v2 --json)" || return
  newest="$(jq -r --arg root "$BASM_ROOT" 'map(select(.paths == [$root])) | sort_by(.time) | last | .time // empty' <<< "$snapshots")" || return
  [[ -n "$newest" ]] || fail "No complete BASM backup exists."
  timestamp="$(date -d "$newest" +%s)" || fail "Invalid backup timestamp."
  age=$(( $(date +%s) - timestamp ))
  (( age >= 0 && age < 129600 )) || fail "Latest backup is over 36 hours old or has a future timestamp."
  for file in "$BASM_ROOT" "$BACKUP_LOCATION"; do
    used="$(df --output=pcent "$file" | tail -1 | tr -dc '0-9')" || return
    [[ "$used" =~ ^[0-9]+$ ]] && (( used < 90 )) || fail "Filesystem for $file is at least 90% full."
  done
  rm -f "$BASM_ROOT/logs/last-failure"
  log "BASM applications, backups and disk space are healthy."
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/releases.sh"
