#!/usr/bin/env bash

scheduled_update_window() {
  local hour="$1"
  [[ "$hour" =~ ^[0-9]{2}$ ]] && (( 10#$hour < 6 ))
}

image_version() {
  local service="$1" image="$2" version metadata key
  case "$service" in
    nextcloud) key=NEXTCLOUD_VERSION ;;
    erp-db|nextcloud-db) key=MARIADB_VERSION ;;
    *) fail "No migration policy for $service" ;;
  esac
  metadata="$(docker image inspect --format '{{json .Config.Env}}' "$image")" || return
  version="$(jq -er --arg key "$key=" '.[] | select(startswith($key)) | split("=")[1]' <<< "$metadata")" || return
  if [[ "$service" == nextcloud ]]; then
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "Cannot identify installed version of $service."
    version="${version%%.*}"
  else
    version="${version#*:}"
    [[ "$version" =~ ^([0-9]+\.[0-9]+)\. ]] || fail "Cannot identify MariaDB series for $service."
    version="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "$version"
}

validate_update_versions() {
  local old="$1" candidate="$2" release="$3" service previous next migration
  MIGRATIONS=()
  for service in nextcloud erp-db nextcloud-db; do
    previous="$(jq -er --arg service "$service" '.[$service]' <<< "$old")" || return
    next="$(jq -er --arg service "$service" '.services[$service].image' <<< "$candidate")" || return
    next="$(image_version "$service" "$next")" || return
    if [[ "$service" == nextcloud ]]; then
      (( next >= previous && next <= previous + 1 )) ||
        fail "Nextcloud requires sequential major upgrades; downgrades are not supported."
    elif [[ "$previous" != "$next" ]]; then
      [[ "$(printf '%s\n%s\n' "$previous" "$next" | sort -V | head -1)" == "$previous" ]] ||
        fail "Database downgrades are not supported."
      migration="$release/migrations/$service-$previous-$next.sh"
      [[ -f "$migration" && ! -L "$migration" ]] ||
        fail "Release requires a tested migration: $service-$previous-$next.sh"
      bash -n "$migration" || return
      MIGRATIONS+=("$migration")
    fi
  done
  previous="$(jq -er '.["erpnext-backend"]' <<< "$old")" || return
  next="$(jq -er '.services["erpnext-backend"].image' <<< "$candidate")" || return
  [[ "$next" =~ :v([0-9]+)([.@-]|$) ]] || fail "ERPNext needs an explicit major-version channel."
  next="${BASH_REMATCH[1]}"
  if [[ "$previous" != "$next" ]]; then
    (( next == previous + 1 )) || fail "ERPNext requires sequential major upgrades; downgrades are not supported."
    migration="$release/migrations/erpnext-$previous-$next.sh"
    [[ -f "$migration" && ! -L "$migration" ]] || fail "Release lacks a tested ERPNext major migration."
    bash -n "$migration" || return
    MIGRATIONS+=("$migration")
  fi
}

installed_versions() {
  local service container image version result='{}'
  for service in nextcloud erp-db nextcloud-db; do
    container="$(basm_stack ps --all -q "$service")" || return
    [[ -n "$container" ]] || fail "Missing installed container: $service"
    image="$(docker inspect --format '{{.Image}}' "$container")" || return
    version="$(image_version "$service" "$image")" || return
    result="$(jq --arg service "$service" --arg version "$version" '.[$service]=$version' <<< "$result")" || return
  done
  image="$(basm_compose -f "$BASM_ROOT/docker-compose.yml" --env-file "$BASM_ENV_FILE" config --format json |
    jq -er '.services["erpnext-backend"].image')" || return
  [[ "$image" =~ :v([0-9]+)([.@-]|$) ]] || fail "Cannot identify ERPNext release channel."
  result="$(jq --arg version "${BASH_REMATCH[1]}" '.["erpnext-backend"]=$version' <<< "$result")" || return
  printf '%s\n' "$result"
}

resolve_release_images() {
  local configuration="$1" destination="$2" service image digest result='{"services":{}}'
  while IFS=$'\t' read -r service image; do
    digest="$(docker image inspect --format '{{json .RepoDigests}}' "$image")" || return
    digest="$(jq -er '.[0] | select(test("@sha256:[a-f0-9]{64}$"))' <<< "$digest")" || return
    result="$(jq --arg service "$service" --arg image "$digest" \
      '.services[$service]={image:$image}' <<< "$result")" || return
  done < <(jq -r '.services | to_entries[] | [.key,.value.image] | @tsv' <<< "$configuration")
  printf '%s\n' "$result" > "$destination"
}

remove_legacy_postal_settings() {
  local temporary
  if ! grep -q '^POSTAL_[A-Z0-9_]*=' "$BASM_ENV_FILE"; then return 0; fi
  temporary="$(mktemp "${BASM_ENV_FILE}.XXXXXX")" || return
  if ! sed '/^POSTAL_[A-Z0-9_]*=/d' "$BASM_ENV_FILE" > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod 600 "$temporary" || { rm -f "$temporary"; return 1; }
  chown --reference="$BASM_ENV_FILE" "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$BASM_ENV_FILE"
}

refresh_dns_handover() {
  local handover_dir="$BASM_ROOT/handover" dns_file="$BASM_ROOT/handover/dns-records.txt"
  [[ ! -L "$handover_dir" ]] || fail "DNS handover directory must not be a symbolic link."
  if [[ ! -e "$handover_dir" ]]; then return 0; fi
  [[ -d "$handover_dir" ]] || fail "DNS handover path is not a directory."
  [[ ! -L "$dns_file" ]] || fail "DNS handover document must not be a symbolic link."
  [[ ! -e "$dns_file" || -f "$dns_file" ]] || fail "DNS handover path is not a regular file."
  write_dns_records "$dns_file" || return
  chmod 600 "$dns_file"
}

refresh_legacy_postal_handover() {
  local handover_dir="$BASM_ROOT/handover" file="$BASM_ROOT/handover/for-it.txt" temporary
  [[ ! -L "$handover_dir" ]] || fail "Handover directory must not be a symbolic link."
  if [[ ! -e "$handover_dir" ]]; then return 0; fi
  [[ -d "$handover_dir" ]] || fail "Handover path is not a directory."
  [[ ! -L "$file" ]] || fail "IT handover document must not be a symbolic link."
  if [[ ! -e "$file" ]]; then return 0; fi
  [[ -f "$file" ]] || fail "IT handover path is not a regular file."
  if ! grep -Fq 'Sign in to Postal using the user document.' "$file"; then return 0; fi
  temporary="$(mktemp "${file}.XXXXXX")" || return
  if ! python3 - "$file" "$temporary" "$PRIMARY_DOMAIN" "${MAILBOX_HOSTNAME:-mx.$PRIMARY_DOMAIN}" \
    "$MAILBOX_SETUP_PORT" "$SMTP_PORT" "$MAILBOX_SUBMISSION_PORT" "$MAILBOX_IMAPS_PORT" <<'PY'
import sys
from pathlib import Path

source, destination, domain, mail_host, setup_port, smtp_port, submission_port, imaps_port = sys.argv[1:]
text = Path(source).read_text()
start_marker = "5. FINISH MAIL SETUP\n"
end_marker = "\nRUSTDESK CLIENT SETUP AND RECOVERY"
start = text.find(start_marker)
end = text.find(end_marker, start + len(start_marker))
if start < 0 or end < 0 or "Sign in to Postal using the user document." not in text[start:end]:
    raise SystemExit("Cannot safely locate the legacy Postal handover section.")
mail_section = f"""5. FINISH MAIL SETUP
Open the Stalwart first-run setup page through an SSH tunnel:
  ssh -L {setup_port}:127.0.0.1:{setup_port} <server-user>@<server-address>
Then open http://127.0.0.1:{setup_port} on that computer. Read the
temporary setup login from the container log:
  sudo docker logs basm-stalwart-mail
Choose {mail_host} as the server hostname and {domain} as the mail domain.
Complete setup, restart the container, then open
https://{mail_host}/admin after its certificate is valid.

Admin sign-in uses OAuth metadata bound to the canonical HTTPS hostname
https://{mail_host}. Do not sign in through localhost, an IP address or the
mail alias; those origins can fail with "Unknown client id." Wait until a
trusted certificate is valid, then sign in at https://{mail_host}/admin and
create the owner's mailbox. From Management -> Domains, publish the complete
generated DNS zone file, merging SPF and DMARC with existing records rather
than adding duplicates or replacing unrelated TXT records. Ensure the mail
host and the autoconfig, autodiscover, mta-sts and ua-auto-config names resolve
before expecting a valid certificate. Do not bypass certificate warnings.
Reverse DNS (PTR) is controlled by the IP address-range owner, not deSEC.
Without PTR control, outbound delivery may be less reliable, but BASM can
still host and send mail.

For ERPNext email, create a dedicated Stalwart sender account and configure
the ERPNext outgoing Email Account with {mail_host}, port 465, SSL/TLS, and
that account's credentials. Do not reuse the Stalwart administrator login.

For production, in Settings -> Network -> Listeners add an HTTPS proxy listener:
name https-proxy, HTTP protocol, bind 0.0.0.0:8443, implicit TLS enabled, and
override proxy trusted networks set only to 172.31.255.2. BASM Traefik sends
PROXY protocol v2 over its isolated mail-proxy network.

Test sending and receiving with Thunderbird, then send a test ERPNext email.
Confirm SPF/DKIM/DMARC and actual delivery before declaring mail operational.
"""
text = text[:start] + mail_section + text[end:]
text = text.replace(
    "It lists the A, MX, SPF, DMARC and Postal records and, for deSEC, a paste-ready",
    "It lists the A, MX, SPF, DMARC and mail-host records and, for deSEC, a paste-ready",
)
text = text.replace(
    "Postal SMTP    TCP         25               25",
    f"Mail SMTP      TCP         25               {smtp_port}\n"
    "Optional mail-client access from outside the LAN/VPN:\n"
    f"Mailbox SMTP   TCP         465              {submission_port}\n"
    f"Mailbox IMAP   TCP         993              {imaps_port}",
)
text = text.replace(
    "Public mail requires external TCP 25.",
    "Internet mail delivery requires external TCP 25. Forward TCP 465 and 993 "
    "only when off-network mail-client access is intended; keep them private "
    "for LAN/VPN clients.",
)
Path(destination).write_text(text)
PY
  then
    rm -f "$temporary"
    return 1
  fi
  chown --reference="$file" "$temporary" || { rm -f "$temporary"; return 1; }
  chmod 600 "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$file"
}

update_deployment() (
  set -euo pipefail
  umask 077
  local release="$1" stage previous candidate file migration channels version current
  local -a MIGRATIONS=()
  [[ ! -e "$BASM_ROOT/config/update-in-progress" ]] ||
    fail "A previous update was interrupted; repair or recover before retrying."
  [[ -f "$release/VERSION" && -f "$release/templates/docker-compose.yml" ]] ||
    fail "Use a trusted BASM release checkout."
  version="$(cat "$release/VERSION")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Release VERSION must be numeric major.minor.patch."
  if [[ -f "$BASM_ROOT/maintenance/VERSION" ]]; then
    current="$(cat "$BASM_ROOT/maintenance/VERSION")"
    [[ "$(printf '%s\n%s\n' "$current" "$version" | sort -V | head -1)" == "$current" ]] ||
      fail "BASM release downgrades are not supported."
  fi
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  mkdir -p "$stage/config"
  previous="$(installed_versions)" || return
  ROOT_DIR="$release" BASM_RENDER_DIR="$stage" render_stack || return
  candidate="$(basm_compose -f "$stage/docker-compose.yml" --env-file "$BASM_ENV_FILE" config --format json)" || return
  basm_compose -f "$stage/docker-compose.yml" --env-file "$BASM_ENV_FILE" pull --quiet || return
  validate_update_versions "$previous" "$candidate" "$release" || return
  resolve_release_images "$candidate" "$stage/images.json" || return
  while IFS= read -r file; do
    [[ "${file%/*}" != "$BASM_ROOT/modules/fluxer" ]] || continue
    # Pull from configured compatible channels, not the current digest lock.
    basm_compose -f "$file" pull --quiet || return
  done < <(module_compose_files "$BASM_ROOT")
  backup_deployment || return
  printf '%s\n' "$(cat "$release/VERSION")" > "$BASM_ROOT/config/update-in-progress" || return
  while IFS= read -r file; do stack_command "$file" stop --timeout 120 || return; done < <(deployment_stacks)
  install -m 600 "$stage/docker-compose.yml" "$BASM_ROOT/docker-compose.yml" || return
  install -m 600 "$stage/config/traefik.yml" "$BASM_ROOT/config/traefik.yml" || return
  install -m 600 "$stage/config/traefik-static.yml" "$BASM_ROOT/config/traefik-static.yml" || return
  install -m 600 "$stage/images.json" "$BASM_ROOT/config/images.json" || return
  install -d -m 755 "$BASM_ROOT/home" || return
  install -m 644 "$stage/home/index.html" "$stage/home/mascot.png" "$BASM_ROOT/home/" || return
  install -m 755 "$release/templates/erpnext-create-site.sh" "$BASM_ROOT/config/erpnext-create-site.sh" || return
  prepare_stalwart_storage || return
  for migration in "${MIGRATIONS[@]}"; do
    BASM_ROOT="$BASM_ROOT" BASM_ENV_FILE="$BASM_ENV_FILE" bash "$migration" || return
  done
  while IFS= read -r file; do
    [[ "${file%/*}" != "$BASM_ROOT/modules/fluxer" ]] || continue
    channels="$(basm_compose -f "$file" config --format json)" || return
    resolve_release_images "$channels" "${file%/*}/.basm-images.json" || return
  done < <(module_compose_files "$BASM_ROOT")
  start_stacks || return
  if module_selected fluxer; then
    # rexctl controls its own release, migrations and pre-upgrade archive.
    source "$ROOT_DIR/modules/fluxer.sh"
    rm -f "$BASM_ROOT/modules/fluxer/.basm-images.json"
    module_update || return
    file="$BASM_ROOT/modules/fluxer/docker-compose.yml"
    record_stack_images "$file" "${file%/*}/.basm-images.json" || return
  fi
  while IFS= read -r file; do check_stack "$file" || return; done < <(deployment_stacks)
  ROOT_DIR="$release" install_runtime || return
  check_deployment --updating || return
  remove_legacy_postal_settings || return
  refresh_dns_handover || return
  refresh_legacy_postal_handover || return
  rm "$BASM_ROOT/config/update-in-progress" || return
  log "BASM update completed. The automatic schedule remains January 1 and July 1 at 03:00."
)
