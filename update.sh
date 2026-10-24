#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
case "${1:-}" in
  --help|-h)
    printf 'Usage: ./update.sh [--scheduled <deployment-directory>]\n'
    exit 0
    ;;
esac
SCHEDULED=false
if [[ $# -eq 2 && "$1" == --scheduled ]]; then
  SCHEDULED=true
  BASM_ROOT="$2"
elif [[ $# -ne 0 ]]; then
  printf 'Usage: ./update.sh [--scheduled <deployment-directory>]\n' >&2
  exit 1
fi
BASM_ROOT="${BASM_ROOT:-/opt/basm}"
PRODUCTION_BASM_ROOT="$BASM_ROOT"
LOCAL_BASM_ROOT="$BASM_ROOT"
if [[ "$LOCAL_BASM_ROOT" == /opt/basm ]]; then LOCAL_BASM_ROOT=/opt/basm-local; fi

source "$ROOT_DIR/modules/core.sh"

require_root
LOCAL_MODE=false
if [[ "$SCHEDULED" == true ]]; then
  BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
else
  select_deployment
fi
load_deployment_env
if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then LOCAL_MODE=true; fi

if [[ "$LOCAL_MODE" == true ]]; then
  [[ -f "$BASM_ROOT/config/basm.env" ]] || fail "No local BASM configuration was found at $BASM_ROOT"
  source "$BASM_ROOT/config/basm.env"
  [[ "${DEPLOYMENT_MODE:-}" == local ]] || fail "The selected configuration is not a local test setup."
  validate_local_bind_address "$BIND_ADDRESS" || fail "Unsafe local bind address."
fi

if [[ ! -f "$BASM_ROOT/docker-compose.yml" ]]; then
  fail "No BASM stack was found at $BASM_ROOT"
fi

umask 077
mkdir -p "$BASM_ROOT/logs" || fail "Cannot create update log directory."
exec 9> "$BASM_ROOT/logs/update.lock"
flock -n 9 || fail "Another BASM update is already running."

if [[ "$SCHEDULED" == true ]]; then
  log "Creating pre-update database dumps"
  basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ENV_FILE" exec -T db-backup sh -ec '
    umask 077
    MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb-dump --skip-ssl --single-transaction --routines --events -h erp-db -uroot --all-databases > /dumps/pre-update-erp.sql
    MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb-dump --skip-ssl --single-transaction --routines --events -h nextcloud-db -uroot --all-databases > /dumps/pre-update-nextcloud.sql
    MYSQL_PWD="$POSTAL_DB_PASSWORD" mariadb-dump --skip-ssl --single-transaction --routines --events -h postal-db -uroot --all-databases > /dumps/pre-update-postal.sql
  ' || fail "Pre-update database backup failed; no applications were updated."
  log "Creating encrypted pre-update snapshot"
  basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ENV_FILE" exec -T restic-backup restic backup --tag basm-pre-update /source/erpnext /source/nextcloud /source/postal-db-dumps /source/config || fail "Pre-update snapshot failed; no applications were updated."
fi

log "Pulling latest Docker images"
basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" pull --quiet || fail "Failed to pull new images"

log "Recreating containers with preserved volumes"
basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" up -d --wait --wait-timeout 900 --remove-orphans || fail "Failed to recreate containers or pass health checks"

while IFS= read -r compose_file; do
  log "Updating module stack $compose_file"
  basm_compose -f "$compose_file" pull --quiet || fail "Failed to pull images for $compose_file"
  basm_compose -f "$compose_file" up -d --wait --wait-timeout 300 --remove-orphans || fail "Failed to recreate $compose_file or pass health checks"
done < <(module_compose_files "$BASM_ROOT")

log "Validating BASM stack health"
basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ROOT/config/basm.env" ps || fail "Stack health validation failed"

log "Update completed successfully"
