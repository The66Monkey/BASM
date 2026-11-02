#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir "$TEMP/disk" "$TEMP/host-share" "$TEMP/network-share" "$TEMP/windows-share"

findmnt() {
  if [[ "$1" == --list ]]; then
    printf '%s\n' '{"filesystems":[
      {"target":"/","source":"/dev/vda1","options":"rw,relatime"},
      {"target":"/boot/efi","source":"/dev/vda15","options":"rw"},
      {"target":"'"$TEMP"'/disk","source":"/dev/vdb1","options":"rw"},
      {"target":"'"$TEMP"'/host-share","source":"basm-backup","fstype":"virtiofs","options":"rw"},
      {"target":"'"$TEMP"'/network-share","source":"backup-server:/basm","fstype":"nfs4","options":"rw"},
      {"target":"'"$TEMP"'/windows-share","source":"//backup-server/basm","fstype":"cifs","options":"rw"},
      {"target":"/mnt/readonly","source":"/dev/vdc1","options":"ro"},
      {"target":"/mnt/readonly-share","source":"readonly","fstype":"virtiofs","options":"ro"},
      {"target":"/mnt/unrelated","source":"tmpfs","fstype":"tmpfs","options":"rw"},
      {"target":"/var/lib/docker/test","source":"/dev/vdd1","options":"rw"}
    ]}'
  elif [[ "${*: -1}" == "$TEMP/disk" || "${*: -1}" == "$TEMP/"*share ]]; then
    printf '252:16\n'
  else
    printf '252:1\n'
  fi
}

[[ "$(select_backup_destination /var/backups/basm <<< '' 2>"$TEMP/menu")" == /var/backups/basm ]]
grep -q 'system filesystem' "$TEMP/menu"
grep -q '2) /dev/vdb1' "$TEMP/menu"
grep -q '3) basm-backup' "$TEMP/menu"
grep -q '4) backup-server:/basm' "$TEMP/menu"
grep -q '5) //backup-server/basm' "$TEMP/menu"
grep -q '6) Custom directory' "$TEMP/menu"
! grep -q '/boot/efi\|/mnt/readonly\|/mnt/unrelated\|/var/lib/docker' "$TEMP/menu"

[[ "$(select_backup_destination /var/backups/basm <<< '2' 2>"$TEMP/menu")" == "$TEMP/disk/basm-backups" ]]
! grep -q 'system filesystem' "$TEMP/menu"
[[ "$(select_backup_destination /var/backups/basm <<< '3' 2>"$TEMP/menu")" == "$TEMP/host-share/basm-backups" ]]
! grep -q 'system filesystem' "$TEMP/menu"
[[ "$(select_backup_destination /var/backups/basm <<< '4' 2>"$TEMP/menu")" == "$TEMP/network-share/basm-backups" ]]
[[ "$(select_backup_destination /var/backups/basm <<< '5' 2>"$TEMP/menu")" == "$TEMP/windows-share/basm-backups" ]]
[[ "$(printf '0\n9999\n6\nrelative\n/srv/backups\n' | select_backup_destination /var/backups/basm 2>"$TEMP/menu")" == /srv/backups ]]
grep -q 'Choose one of' "$TEMP/menu"
grep -q 'Invalid value' "$TEMP/menu"
[[ "$(select_backup_destination /var/backups/basm <<< '/srv/backups' 2>"$TEMP/menu")" == /srv/backups ]]
if (select_backup_destination /var/backups/basm </dev/null >"$TEMP/output" 2>"$TEMP/menu"); then
  exit 1
fi
grep -q 'No backup destination selection' "$TEMP/menu"
printf 'Backup destination checks passed.\n'
