#!/usr/bin/env bash
# Keeps the deSEC A records of a non-static-IP BASM install on the current public IPv4.
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BASM_ROOT="${1:?Usage: ddns-update.sh <BASM_ROOT>}"
STATE_FILE="$BASM_ROOT/config/last-public-ip"
LOG_FILE="$BASM_ROOT/logs/ddns.log"

source "$BASM_ROOT/config/basm.env"
[[ "${IP_MODE:-static}" == non-static && -n "${DESEC_TOKEN:-}" ]] || exit 0

note() { printf '%s: %s\n' "$(date -Is)" "$1" >> "$LOG_FILE"; }

current_ip="$(curl -4 -fsS --max-time 20 https://api.ipify.org || true)"
if [[ ! "$current_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  note "Could not determine the public IPv4 address."
  exit 1
fi
last_ip="$(cat "$STATE_FILE" 2>/dev/null || true)"
[[ "$current_ip" != "$last_ip" ]] || exit 0

hostnames=("$PRIMARY_DOMAIN" "$ERP_URL" "$MAIL_URL" "$CLOUD_URL" "mx.$PRIMARY_DOMAIN")
if [[ " ${BASM_MODULES:-basm} " == *" fluxer "* && -n "${FLUXER_DOMAIN:-}" ]]; then
  hostnames+=("$FLUXER_DOMAIN")
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
