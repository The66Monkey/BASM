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
Usage: ./install.sh [--module <module-name> | --full | --promote] [--help]

  (no option)         Run the setup wizard (new install or reconfigure)
  --module <name>     Add one module to an existing install
  --full              Upgrade an existing basic install to the full profile
                      (Core + LAMP + WireGuard + Uptime Kuma); core is untouched
  --promote           Replace the local test install with a fresh production
                      install, reusing installed packages and cached images

Examples:
  ./install.sh
  ./install.sh --module wireguard
  ./install.sh --full
  ./install.sh --promote
EOF
}

MODULE_NAME=""
ACTION=install
PRODUCTION_BASM_ROOT="$BASM_ROOT"
LOCAL_BASM_ROOT="$BASM_ROOT"
if [[ "$LOCAL_BASM_ROOT" == /opt/basm ]]; then LOCAL_BASM_ROOT=/opt/basm-local; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module|--full|--promote)
      [[ "$ACTION" == install ]] || fail "Use only one of --module, --full, or --promote."
      ;;&
    --module)
      [[ $# -ge 2 ]] || fail "--module requires a value"
      MODULE_NAME="$2"
      ACTION=module
      shift 2
      ;;
    --full)
      ACTION=full
      shift
      ;;
    --promote)
      ACTION=promote
      shift
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

case "$ACTION" in
  module)
    select_deployment
    load_deployment_env
    if [[ "$MODULE_NAME" == basm ]]; then
      run_module_install basm
    else
      upgrade_modules "$MODULE_NAME"
    fi
    exit $?
    ;;
  full)
    select_deployment
    load_deployment_env
    upgrade_to_full
    exit $?
    ;;
  promote)
    promote_to_production
    exit $?
    ;;
esac

run_wizard
configure_system
install_selected_modules
write_summary

log "BASM installation completed. Review the generated summary in $OUTPUT_DIR."
