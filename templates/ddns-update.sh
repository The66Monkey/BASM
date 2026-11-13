#!/usr/bin/env bash
# Keeps the deSEC A records of a dynamic-IP BASM install on the current public IPv4.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/modules/core.sh"
BASM_ROOT="${1:?Usage: ddns-update.sh <BASM_ROOT>}"
STATE_FILE="$BASM_ROOT/config/last-public-ip"
LOG_FILE="$BASM_ROOT/logs/ddns.log"

BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
load_deployment_env
[[ "${IP_MODE:-non-static}" == non-static && -n "${DESEC_TOKEN:-}" ]] || exit 0
acquire_operation_lock check
install_operation_trap "Dynamic DNS update"

note() { printf '%s: %s\n' "$(date -Is)" "$1" >> "$LOG_FILE"; }

valid_ipv4() {
  local octet
  local -a octets
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$1"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || return 1
  done
}

current_ip=""
for endpoint in https://api.ipify.org https://checkip.amazonaws.com; do
  if response="$(curl -4 -fsS --max-time 10 "$endpoint" 2>/dev/null)" && valid_ipv4 "$response"; then
    current_ip="$response"
    break
  fi
done
if [[ -z "$current_ip" ]]; then
  note "Could not determine the public IPv4 address from either lookup service."
  exit 1
fi
last_ip="$(cat "$STATE_FILE" 2>/dev/null || true)"
[[ "$current_ip" != "$last_ip" ]] || exit 0

hostnames=("$PRIMARY_DOMAIN" "$ERP_URL" "$MAIL_URL" "$CLOUD_URL" "mx.$PRIMARY_DOMAIN")
if [[ " ${BASM_MODULES:-basm} " == *" fluxer "* && -n "${FLUXER_DOMAIN:-}" ]]; then
  hostnames+=("$FLUXER_DOMAIN")
fi
if [[ " ${BASM_MODULES:-basm} " == *" hotdog "* ]]; then
  hostnames+=("hotdog.$PRIMARY_DOMAIN")
fi
hostnames="$(printf '%s\n' "${hostnames[@]}" | sort -u | paste -sd, -)"
note "Public IP changed from ${last_ip:-unknown} to $current_ip; updating $hostnames"
# The token is passed on stdin so it never appears in the process list.
if ! printf 'header = "Authorization: Token %s"\n' "$DESEC_TOKEN" |
  curl -4 -fsS --max-time 30 -K - -o /dev/null \
    "https://update.dedyn.io/?hostname=$hostnames&myipv4=$current_ip&myipv6=preserve"; then
  note "deSEC update failed; will retry on the next run."
  exit 1
fi
printf '%s\n' "$current_ip" > "$STATE_FILE"
note "Updated $hostnames -> $current_ip"
