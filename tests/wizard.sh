#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'status=$?; if (( status != 0 )); then tail -n 40 "$TEMP/"*.log; fi; rm -rf "$TEMP"; exit "$status"' EXIT
LOCAL_BASM_ROOT="$TEMP/local"
PRODUCTION_BASM_ROOT="$TEMP/production"
port_in_use() { return 1; }
findmnt() {
  if [[ "$1" == --list ]]; then
    printf '{"filesystems":[]}\n'
  else
    printf '252:1\n'
  fi
}

# Reject a production plan, then accept local mode without leaking discarded choices.
(
  run_wizard < <(
    printf 'first.example\nDiscarded Company\nops@first.dk\n\n\n%s\n\n\n\nN\n' "$TEMP/discarded-backups"
    printf 'synthetic-desec-token-123456\n2 4\nyes\nstandard\nR\n'
    printf 'local\n\nAccepted Company\n\n\n\n\n\n\n\n\ninvalid\nA\n'
  )
  [[ "$DEPLOYMENT_MODE" == local && "$BIND_ADDRESS" == 127.0.0.1 ]]
  [[ "$MANAGEMENT_BIND_ADDRESS" == 127.0.0.1 && "$SMTP_BIND_ADDRESS" == 127.0.0.1 ]]
  [[ "$COMPANY_NAME" == 'Accepted Company' && "$ADMIN_EMAIL" == admin@example.com ]]
  [[ "$PRIMARY_DOMAIN" == localhost && "$ERP_URL" == erp.localhost ]]
  [[ "$PORT_PROFILE" == local && "$HTTP_PORT" == 18080 ]]
  [[ "$BASM_MODULES" == basm && -z "$DESEC_TOKEN" ]]
  [[ "$ERP_EXAMPLES" == no ]]
  [[ "$BACKUP_LOCATION" == "$LOCAL_BASM_ROOT/backups" ]]
  [[ ! -e "$PRODUCTION_BASM_ROOT/config/basm.env" ]]
  [[ -f "$LOCAL_BASM_ROOT/config/basm.env" ]]
) >"$TEMP/restart.log" 2>&1
[[ "$(grep -c 'Review BASM setup' "$TEMP/restart.log")" == 2 ]]
grep -Fq 'Enter A to accept' "$TEMP/restart.log"
grep -Fq 'system filesystem' "$TEMP/restart.log"
grep -Fq 'Local access: HTTP on the selected bind address.' "$TEMP/restart.log"
! grep -Fq 'Do not forward' "$TEMP/restart.log"
if grep -Fq 'synthetic-desec-token' "$TEMP/restart.log" || grep -q $'\033' "$TEMP/restart.log"; then
  fail "Wizard review exposed a token or emitted terminal controls into redirected output."
fi

cp "$LOCAL_BASM_ROOT/config/basm.env" "$TEMP/original.env"
(
  run_wizard < <(printf 'local\n\nCancelled Company\n\n\n\n\n\n\n\nC\n')
  printf 'UNEXPECTED-CONTINUATION\n'
) >"$TEMP/cancel.log" 2>&1
cmp "$TEMP/original.env" "$LOCAL_BASM_ROOT/config/basm.env"
! grep -Fq UNEXPECTED-CONTINUATION "$TEMP/cancel.log"
grep -Fq 'Installation cancelled' "$TEMP/cancel.log"

if (
  run_wizard < <(printf 'local\n\nUnconfirmed Company\n\n\n\n\n\n\n\n')
) >"$TEMP/eof.log" 2>&1; then
  fail "Wizard accepted end-of-input as confirmation."
fi
cmp "$TEMP/original.env" "$LOCAL_BASM_ROOT/config/basm.env"
grep -Fq 'Could not read setup confirmation' "$TEMP/eof.log"

# Existing credentials must stay private in the pre-install review.
(
  collect_wizard_settings < <(printf 'local\n\n\n\n\n\n\n\n\n\n')
  DB_ROOT_PASSWORD=synthetic-private-password
  DESEC_TOKEN=synthetic-private-token
  review_wizard <<< A
) >"$TEMP/private.log" 2>&1
! grep -Fq synthetic-private "$TEMP/private.log"

(
  run_wizard < <(printf '%s\n' local '' '' '' '' '' '' '' invalid Y '' A)
  [[ "$ERP_EXAMPLES" == yes ]]
  grep -Fxq 'ERP_EXAMPLES="yes"' "$LOCAL_BASM_ROOT/config/basm.env"
  run_wizard < <(printf '%s\n' local '' '' '' '' '' '' '' '' '' A)
  [[ "$ERP_EXAMPLES" == yes ]]
) >"$TEMP/examples.log" 2>&1
grep -Fq 'Invalid value for Include ERPNext learning examples?' "$TEMP/examples.log"

python3 - "$ROOT_DIR" "$LOCAL_BASM_ROOT/config/basm.env" <<'PY'
import errno
import os
import pty
import select
import subprocess
import sys

for term in ("xterm", "dumb"):
    master, slave = pty.openpty()
    process = subprocess.Popen(
        ["bash", "-c",
         'ROOT_DIR="$1"; source "$ROOT_DIR/modules/core.sh"; BASM_ENV_FILE="$2"; read_deployment_settings; review_wizard',
         "bash", sys.argv[1], sys.argv[2]],
        stdin=slave, stdout=slave, stderr=slave, env={**os.environ, "TERM": term},
    )
    os.close(slave)
    output = bytearray()
    try:
        os.write(master, b"A\n")
        while True:
            assert select.select([master], [], [], 10)[0], "Terminal review timed out"
            try:
                data = os.read(master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not data:
                break
            output.extend(data)
        assert process.wait(timeout=5) == 0, output.decode()
        assert (b"\033[H\033[2J" in output) == (term == "xterm")
        assert b"Review BASM setup" in output
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
        process.wait()
PY
printf 'Wizard accept/restart/cancel, EOF and private-summary checks passed.\n'
