#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES_DIR="$ROOT_DIR/modules"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$MODULES_DIR/core.sh"
/usr/bin/python3 -c 'import pykeepass' || { printf 'Install python3-pykeepass to run KeePass tests.\n' >&2; exit 1; }
LOCAL_BASM_ROOT="$TEST_DIR/local"
PRODUCTION_BASM_ROOT="$TEST_DIR/production"
OUTPUT_DIR="$TEST_DIR/output"
mkdir -p "$OUTPUT_DIR"
port_in_use() { return 1; }
dpkg-query() { printf 'install ok installed'; }
apt-get() { printf 'Unexpected package installation in KeePass tests.\n' >&2; return 1; }
run_wizard < <(printf 'local\n\n\n\n\n\n\n7\n\nA\n')
[[ "$BASM_MODULES" == 'basm keepass' ]]
mkdir -p "$BASM_ROOT/config/prepared-modules/wireguard"
printf 'server-test-key' > "$BASM_ROOT/config/prepared-modules/wireguard/config.conf"
printf 'peer-test-key' > "$BASM_ROOT/config/prepared-modules/wireguard/peer1.conf"
DESEC_TOKEN="$(generate_password)"
export DESEC_TOKEN
run_module_install keepass
write_summary
USER_HANDOVER="$BASM_ROOT/handover/for-the-user.txt"
IT_HANDOVER="$BASM_ROOT/handover/for-it.txt"
MASTER_FILE="$BASM_ROOT/config/keepass-master-password"
DATABASE="$BASM_ROOT/vaults/admin/credentials.kdbx"
master="$(< "$MASTER_FILE")"
[[ "$master" =~ ^[A-Za-z0-9]{32}$ ]]
[[ "$(stat -c '%a' "$DATABASE")" == 600 ]]
[[ "$(stat -c '%a' "$MASTER_FILE")" == 600 ]]
[[ "$(stat -c '%a' "$USER_HANDOVER")" == 600 ]]
[[ "$(grep -c '^Master password:' "$USER_HANDOVER")" == 1 ]]
grep -Fq "Master password: $master" "$USER_HANDOVER"
for variable in ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD DB_ROOT_PASSWORD NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD DESEC_TOKEN; do
  if grep -Fq "${!variable}" "$USER_HANDOVER" "$IT_HANDOVER" "$OUTPUT_DIR/local-installation-summary.txt"; then
    printf 'Service credential leaked into handover: %s\n' "$variable" >&2
    exit 1
  fi
done
if grep -Fq "$master" "$IT_HANDOVER" "$OUTPUT_DIR/local-installation-summary.txt"; then exit 1; fi
if grep -Eq '^Username:|^Initial password:' "$USER_HANDOVER"; then exit 1; fi
/usr/bin/python3 - "$BASM_ROOT" <<'PY'
import os
from pathlib import Path
import sys
from pykeepass import PyKeePass

root = Path(sys.argv[1])
database = root / "vaults/admin/credentials.kdbx"
master = (root / "config/keepass-master-password").read_text().strip()
vault = PyKeePass(database, password=master)
group = vault.find_groups(name="BASM", first=True)
expected = {
    "ERPNext administrator": "ERP_ADMIN_PASSWORD",
    "Nextcloud administrator": "NEXTCLOUD_ADMIN_PASSWORD",
    "ERPNext database root": "DB_ROOT_PASSWORD",
    "Nextcloud database root": "DB_ROOT_PASSWORD",
    "Nextcloud application database": "NEXTCLOUD_DB_PASSWORD",
    "Restic backup encryption": "RESTIC_PASSWORD",
    "deSEC API token": "DESEC_TOKEN",
}
for title, variable in expected.items():
    entry = vault.find_entries(title=title, group=group, first=True)
    assert entry.password == os.environ[variable], title
    assert os.environ[variable].encode() not in database.read_bytes(), title
for title, content in (("WireGuard config.conf", b"server-test-key"), ("WireGuard peer1.conf", b"peer-test-key")):
    entry = vault.find_entries(title=title, group=group, first=True)
    assert entry.attachments[0].data == content, title
vault.find_entries(title="Nextcloud administrator", group=group, first=True).password = "OwnerChangedPassword"
vault.save()
PY
BASM_MODULES+=' uptime-kuma'
write_summary
[[ "$(< "$MASTER_FILE")" == "$master" ]]
/usr/bin/python3 - "$BASM_ROOT" <<'PY'
from pathlib import Path
import sys
from pykeepass import PyKeePass

root = Path(sys.argv[1])
master = (root / "config/keepass-master-password").read_text().strip()
vault = PyKeePass(root / "vaults/admin/credentials.kdbx", password=master)
assert vault.find_entries(title="Nextcloud administrator", first=True).password == "OwnerChangedPassword"
assert len(vault.find_entries(title="ERPNext administrator")) == 1
assert vault.find_entries(title="Uptime Kuma administrator", first=True).url == "http://127.0.0.1:18301"
PY
checksum="$(sha256sum "$DATABASE")"
touch "$DATABASE.lock"
if sync_keepass >/dev/null 2>&1; then exit 1; fi
[[ "$(sha256sum "$DATABASE")" == "$checksum" ]]
rm "$DATABASE.lock"
mv "$DATABASE" "$BASM_ROOT/config/credentials.kdbx"
sync_keepass >/dev/null
[[ -f "$DATABASE" && ! -e "$BASM_ROOT/config/credentials.kdbx" ]]
[[ -f "$BASM_ROOT/config/credentials.kdbx.pre-share" ]]
cp "$DATABASE" "$BASM_ROOT/config/credentials.kdbx"
checksum="$(sha256sum "$DATABASE")"
if sync_keepass >/dev/null 2>&1; then exit 1; fi
[[ "$(sha256sum "$DATABASE")" == "$checksum" ]]
rm "$BASM_ROOT/config/credentials.kdbx"
mv "$DATABASE" "$BASM_ROOT/config/credentials.kdbx"
backup_checksum="$(sha256sum "$BASM_ROOT/config/credentials.kdbx.pre-share")"
if sync_keepass >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$DATABASE" ]]
[[ "$(sha256sum "$BASM_ROOT/config/credentials.kdbx.pre-share")" == "$backup_checksum" ]]
mv "$BASM_ROOT/config/credentials.kdbx" "$DATABASE"
if [[ "$EUID" == 0 ]]; then
  chown 65534:65534 "$DATABASE"
  sync_keepass >/dev/null
  [[ "$(stat -c '%u:%g' "$DATABASE")" == 65534:65534 ]]
fi
checksum="$(sha256sum "$DATABASE")"
mv "$MASTER_FILE" "$MASTER_FILE.saved"
if sync_keepass >/dev/null 2>&1; then exit 1; fi
[[ "$(sha256sum "$DATABASE")" == "$checksum" ]]
mv "$MASTER_FILE.saved" "$MASTER_FILE"
DEPLOYMENT_MODE=production
write_summary
grep -Fq 'YOUR KEEPASS ACCESS' "$USER_HANDOVER"
if grep -Fq "$NEXTCLOUD_ADMIN_PASSWORD" "$USER_HANDOVER" "$IT_HANDOVER" "$OUTPUT_DIR/installation-summary.txt"; then exit 1; fi
printf 'KeePass tests passed.\n'