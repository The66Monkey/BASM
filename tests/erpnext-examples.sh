#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BASM_ROOT="$TEMP/deployment"
BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
BASM_CRON_DIR="$TEMP/cron"
ERP_URL=erp.example.test
mkdir -p "$BASM_ROOT/config" "$BASM_ROOT/logs"
CALLS="$TEMP/calls"
basm_stack() {
  printf '%s\n' "$*" >> "$CALLS"
  cmp - "$ROOT_DIR/templates/erpnext-examples.py"
  return "${STACK_STATUS:-0}"
}
ERP_EXAMPLES=no
seed_erp_examples
[[ ! -e "$CALLS" ]]
unset ERP_EXAMPLES
seed_erp_examples
[[ ! -e "$CALLS" ]]
ERP_EXAMPLES=yes
seed_erp_examples
grep -Fxq "exec -T erpnext-backend ./env/bin/python - $ERP_URL" "$CALLS"
STACK_STATUS=19
if seed_erp_examples; then
  fail "ERPNext seeding errors were hidden."
else
  [[ $? == 19 ]]
fi
unset STACK_STATUS
touch "$BASM_ROOT/config/update-in-progress"
if (seed_erp_examples) >"$TEMP/failure.log" 2>&1; then
  fail "Examples ran during an interrupted update."
fi
rm "$BASM_ROOT/config/update-in-progress"
ERP_EXAMPLES=invalid
if (seed_erp_examples) >"$TEMP/failure.log" 2>&1; then
  fail "Invalid example setting was accepted."
fi

ensure_packages() { :; }
systemctl() { :; }
ERP_EXAMPLES=yes
install_auto_updates
cron_file="$(examples_cron_file "$BASM_ROOT")"
grep -Fq '*/5 * * * * root /bin/bash' "$cron_file"
grep -Fq -- '--root' "$cron_file"
grep -Fq 'examples >>' "$cron_file"
[[ "$(stat -c %a "$cron_file")" == 644 ]]
cmp "$ROOT_DIR/templates/erpnext-examples.py" "$BASM_ROOT/maintenance/templates/erpnext-examples.py"
ERP_EXAMPLES=no
install_auto_updates
[[ ! -e "$cron_file" ]]

(
  exec 8>"$BASM_ROOT/logs/update.lock"
  flock -n 8
  bash -c '
    set -euo pipefail
    ROOT_DIR="$1"; source "$ROOT_DIR/modules/core.sh"
    unset BASM_LOCK_ROOT
    BASM_ROOT="$2"; acquire_operation_lock examples
    exit 42
  ' _ "$ROOT_DIR" "$BASM_ROOT"
)

# Only the old setting is absent, not a malformed or executable configuration.
printf 'ERP_URL="erp.example.test"\n' > "$BASM_ENV_FILE"
unset ERP_EXAMPLES
read_deployment_settings
[[ "${ERP_EXAMPLES:-no}" == no ]]
printf 'ERP_EXAMPLES="yes"\n' >> "$BASM_ENV_FILE"
read_deployment_settings
[[ "$ERP_EXAMPLES" == yes ]]
printf 'ERPNext example opt-in, scheduling, locking and failure checks passed.\n'
