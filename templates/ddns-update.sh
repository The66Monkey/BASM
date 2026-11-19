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
primary_hostnames=("$PRIMARY_DOMAIN" "$ERP_URL" "$MAIL_URL" "$CLOUD_URL" "mx.$PRIMARY_DOMAIN")
if [[ " ${BASM_MODULES:-basm} " == *" fluxer "* && -n "${FLUXER_DOMAIN:-}" ]]; then
  primary_hostnames+=("$FLUXER_DOMAIN")
fi
if [[ " ${BASM_MODULES:-basm} " == *" hotdog "* ]]; then
  primary_hostnames+=("hotdog.$PRIMARY_DOMAIN")
fi
if [[ " ${BASM_MODULES:-basm} " == *" lamp "* && "${DEPLOYMENT_MODE:-production}" != local ]]; then
  primary_hostnames+=("lamp.$PRIMARY_DOMAIN")
fi
hostnames="$(printf '%s\n' "${primary_hostnames[@]}" | sort -u | paste -sd, -)"
update_groups=("$hostnames")
managed_hostnames="$hostnames"
if [[ -f "$BASM_ROOT/config/ddns-extra-hostnames" ]]; then
  while IFS= read -r hostname || [[ -n "$hostname" ]]; do
    [[ -n "$hostname" ]] || continue
    if ! validate_domain "$hostname"; then
      note "Invalid hostname in config/ddns-extra-hostnames: $hostname"
      exit 1
    fi
    hostname="${hostname,,}"
    if [[ ",$managed_hostnames," != *",$hostname,"* ]]; then
      # deSEC's update API requires each request to stay within one DNS zone.
      update_groups+=("$hostname")
      managed_hostnames+=",$hostname"
    fi
  done < "$BASM_ROOT/config/ddns-extra-hostnames"
fi

last_ip="" last_hostnames=""
if [[ -f "$STATE_FILE" ]]; then
  last_ip="$(sed -n '1p' "$STATE_FILE")"
  last_hostnames="$(sed -n '2p' "$STATE_FILE")"
fi
[[ "$current_ip" != "$last_ip" || "$managed_hostnames" != "$last_hostnames" ]] || exit 0

note "Public IP or managed hostnames changed; updating $managed_hostnames -> $current_ip"
for hostnames in "${update_groups[@]}"; do
  # The token is passed on stdin so it never appears in the process list.
  if ! printf 'header = "Authorization: Token %s"\n' "$DESEC_TOKEN" |
    curl -4 -fsS --max-time 30 -K - -o /dev/null \
      "https://update.dedyn.io/?hostname=$hostnames&myipv4=$current_ip&myipv6=preserve"; then
    note "deSEC update failed for $hostnames; will retry on the next run."
    exit 1
  fi
done
printf '%s\n%s\n' "$current_ip" "$managed_hostnames" > "$STATE_FILE.tmp"
mv -f "$STATE_FILE.tmp" "$STATE_FILE"
note "Updated $managed_hostnames -> $current_ip"
