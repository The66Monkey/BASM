#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$ROOT_DIR/config"
MODULES_DIR="$ROOT_DIR/modules"
TEMPLATES_DIR="$ROOT_DIR/templates"
OUTPUT_DIR="$ROOT_DIR/output"
LOG_FILE="$OUTPUT_DIR/install.log"
BASM_ROOT="${BASM_ROOT:-/opt/basm}"

mkdir -p "$OUTPUT_DIR"

source "$MODULES_DIR/core.sh"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--module <module-name>] [--help]

Examples:
  ./install.sh
  ./install.sh --module wireguard
  ./install.sh --module fluxer
EOF
}

MODULE_NAME=""
PRODUCTION_BASM_ROOT="$BASM_ROOT"
LOCAL_BASM_ROOT="$BASM_ROOT"
if [[ "$LOCAL_BASM_ROOT" == /opt/basm ]]; then LOCAL_BASM_ROOT=/opt/basm-local; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)
      [[ $# -ge 2 ]] || fail "--module requires a value"
      MODULE_NAME="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

require_root
check_debian

if [[ -n "$MODULE_NAME" ]]; then
  select_deployment
  [[ -f "$BASM_ENV_FILE" ]] || fail "Run the full installer for this environment first."
  set -a
  source "$BASM_ENV_FILE"
  set +a
  if [[ "$LOCAL_MODE" == true ]]; then
    [[ "$DEPLOYMENT_MODE" == local ]] || fail "Expected a local environment configuration."
    validate_local_bind_address "$BIND_ADDRESS" || fail "Unsafe local bind address."
  fi
  run_module_install "$MODULE_NAME"
  exit $?
fi

run_wizard
configure_system
install_selected_modules
write_summary

log "BASM installation completed. Review the generated summary in $OUTPUT_DIR."
