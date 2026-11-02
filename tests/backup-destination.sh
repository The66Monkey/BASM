#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir "$TEMP/disk"

findmnt() {
  if [[ "$1" == --real ]]; then
    printf '%s\n' '{"filesystems":[
      {"target":"/","source":"/dev/vda1","options":"rw,relatime"},
      {"target":"/boot/efi","source":"/dev/vda15","options":"rw"},
      {"target":"'"$TEMP"'/disk","source":"/dev/vdb1","options":"rw"},
      {"target":"/mnt/readonly","source":"/dev/vdc1","options":"ro"},
      {"target":"/var/lib/docker/test","source":"/dev/vdd1","options":"rw"}
    ]}'
  elif [[ "${*: -1}" == "$TEMP/disk" ]]; then
    printf '252:16\n'
  else
    printf '252:1\n'
  fi
}

[[ "$(select_backup_destination /var/backups/basm <<< '' 2>"$TEMP/menu")" == /var/backups/basm ]]
grep -q 'system filesystem' "$TEMP/menu"
grep -q '2) /dev/vdb1' "$TEMP/menu"
grep -q '3) Custom directory' "$TEMP/menu"
! grep -q '/boot/efi\|/mnt/readonly\|/var/lib/docker' "$TEMP/menu"

[[ "$(select_backup_destination /var/backups/basm <<< '2' 2>"$TEMP/menu")" == "$TEMP/disk/basm-backups" ]]
! grep -q 'system filesystem' "$TEMP/menu"
[[ "$(printf '0\n9999\n3\nrelative\n/srv/backups\n' | select_backup_destination /var/backups/basm 2>"$TEMP/menu")" == /srv/backups ]]
grep -q 'Choose one of' "$TEMP/menu"
grep -q 'Invalid value' "$TEMP/menu"
[[ "$(select_backup_destination /var/backups/basm <<< '/srv/backups' 2>"$TEMP/menu")" == /srv/backups ]]
if (select_backup_destination /var/backups/basm </dev/null >"$TEMP/output" 2>"$TEMP/menu"); then
  exit 1
fi
grep -q 'No backup destination selection' "$TEMP/menu"
printf 'Backup destination checks passed.\n'
