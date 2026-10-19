#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

module_install() {
  log "Installing backup module"
  ensure_dir "$BASM_ROOT/modules/backup"
  cat > "$BASM_ROOT/modules/backup/restic.conf" <<EOF
# Restic backup configuration
BACKUP_PATHS="/opt/basm /var/lib/docker /etc"
REPOSITORY="/var/backups/basm/restic"
PRUNE_DAYS=30
EOF
  log "Backup module configuration generated"
}
