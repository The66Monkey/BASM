#!/usr/bin/env bash

module_install() {
  log "Backups are integrated into BASM core; installing the coordinated maintenance jobs."
  install_auto_updates
}

restic_command() {
  [[ -d "$BACKUP_LOCATION" && ! -L "$BACKUP_LOCATION" ]] || fail "Backup destination is missing or a symlink."
  check_backup_filesystem || return
  restic_repository_command "$@"
}

check_backup_filesystem() {
  local device_file="$BASM_ROOT/config/backup-device" identity
  if [[ -f "$device_file" ]]; then
    identity="$(backup_filesystem)" || fail "Could not identify the backup filesystem. Check the configured mount."
    [[ "$identity" == "$(< "$device_file")" ]] ||
      fail "Backup filesystem changed or is not mounted. Mount it before continuing."
  fi
}

restic_repository_command() {
  RESTIC_REPOSITORY="$BACKUP_LOCATION/restic" RESTIC_PASSWORD="$RESTIC_PASSWORD" \
    RESTIC_CACHE_DIR="$BACKUP_LOCATION/cache" restic "$@"
}

backup_filesystem() {
  findmnt --json --target "$BACKUP_LOCATION" --output TARGET,SOURCE,UUID |
    jq -ce '.filesystems[0] | select(.target != null) |
      if .uuid != null then {target,uuid} else select(.source != null) | {target,source} end'
}

adopt_backup_mount() (
  set -euo pipefail
  umask 077
  local device_file="$BASM_ROOT/config/backup-device" identity snapshots temporary previous
  [[ -f "$device_file" ]] || fail "No saved backup filesystem exists. Use the installer for a new repository."
  [[ -d "$BACKUP_LOCATION" && ! -L "$BACKUP_LOCATION" &&
    -f "$BACKUP_LOCATION/restic/config" ]] || fail "Mount the existing encrypted repository at the saved backup location first."
  identity="$(backup_filesystem)" || fail "Could not identify the mounted backup filesystem."
  [[ "$(jq -r '.target' <<< "$identity")" != / &&
    "$(stat -c %d "$BACKUP_LOCATION")" != "$(stat -c %d "$BASM_ROOT")" ]] ||
    fail "Mount separate backup storage first; refusing to adopt the deployment filesystem."
  snapshots="$(restic_repository_command snapshots --json)" || return
  jq -e --arg root "$BASM_ROOT" --arg host "$BASM_CONTAINER_PREFIX" \
    'any(.[]; .hostname == $host and .paths == [$root] and
      ((.tags // []) | index("basm-v2")) != null)' <<< "$snapshots" >/dev/null ||
    fail "No complete snapshot for this deployment was found; the saved filesystem is unchanged."
  log "Verifying all backup data before adopting the mounted repository."
  restic_repository_command check --read-data || return
  [[ "$(backup_filesystem)" == "$identity" ]] || fail "Backup filesystem changed during verification."
  previous="$(mktemp "$device_file.before-adopt.XXXXXX")" || return
  cp -p "$device_file" "$previous" || return
  chmod 600 "$previous" || return
  temporary="$(mktemp "$device_file.new.XXXXXX")" || return
  trap 'rm -f "$temporary"' EXIT
  printf '%s\n' "$identity" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$device_file"
  log "Mounted backup repository adopted. Previous filesystem identity saved at $previous."
  log "No backup data was moved or deleted. Test a fresh backup and recovery before removing the old copy."
)

record_stack_images() {
  local file="$1" destination="$2" configuration service image container digest temporary
  configuration="$(stack_command "$file" config --format json)" || return
  temporary="$(mktemp)" || return
  printf '{"services":{}}\n' > "$temporary"
  while IFS=$'\t' read -r service image; do
    container="$(stack_command "$file" ps --all -q "$service")" || { rm -f "$temporary"; return 1; }
    if [[ -n "$container" ]]; then
      image="$(docker inspect --format '{{.Image}}' "$container")" || { rm -f "$temporary"; return 1; }
    fi
    digest="$(docker image inspect --format '{{json .RepoDigests}}' "$image")" || { rm -f "$temporary"; return 1; }
    digest="$(jq -er '.[0] | select(test("@sha256:[a-f0-9]{64}$"))' <<< "$digest")" || {
      rm -f "$temporary"
      warn "No registry digest available for $service; cannot guarantee recovery versions."
      return 1
    }
    configuration="$(jq --arg service "$service" --arg image "$digest" \
      '.services[$service] = {image:$image}' "$temporary")" || { rm -f "$temporary"; return 1; }
    printf '%s\n' "$configuration" > "$temporary"
  done < <(jq -r '.services | to_entries[] | select((.value.profiles // [] | length) == 0) | [.key,.value.image] | @tsv' <<< "$configuration")
  if [[ "$file" == "$BASM_ROOT/docker-compose.yml" ]]; then
    for service in db-backup restic-backup; do
      if grep -Eq "^  $service:" "$file"; then
        configuration="$(jq --arg service "$service" '.services[$service].profiles = ["legacy-backup"]' "$temporary")" || {
          rm -f "$temporary"
          return 1
        }
        printf '%s\n' "$configuration" > "$temporary"
      fi
    done
  fi
  install -m 600 "$temporary" "$destination"
  local result=$?
  rm -f "$temporary"
  return "$result"
}

dump_databases() {
  local service destination
  mkdir -p "$BASM_ROOT/data/db-backups" || return
  chmod 700 "$BASM_ROOT/data/db-backups" || return
  for service in erp-db nextcloud-db postal-db; do
    destination="$BASM_ROOT/data/db-backups/$service.sql"
    basm_stack exec -T "$service" sh -ec \
      'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump --skip-ssl --single-transaction --routines --events -uroot --all-databases' \
      > "$destination.tmp" || return
    [[ -s "$destination.tmp" ]] || { warn "Empty database dump: $service"; return 1; }
    chmod 600 "$destination.tmp" || return
    mv "$destination.tmp" "$destination" || return
  done
}

backup_deployment() (
  set -euo pipefail
  umask 077
  local file running stopped active result=0 index
  local -a files=() services=() writers=() selected=()
  restic_command snapshots >/dev/null || return
  if module_selected fluxer; then
    source "$ROOT_DIR/modules/fluxer.sh"
    module_backup || return
    local archive
    archive="$(find "$BACKUP_LOCATION/fluxer" -maxdepth 1 -type f -name '*.tar.zst' -printf '%T@ %p\n' | sort -nr | head -1)"
    [[ -n "$archive" ]] || fail "Fluxer did not produce a recovery archive."
    cp "${archive#* }" "$BASM_ROOT/data/fluxer-recovery.tar.zst" || return
    install -m 700 "$(command -v rexctl)" "$BASM_ROOT/config/rexctl" || return
  fi
  resume() {
    result=$?
    trap - EXIT INT TERM
    for ((index=${#files[@]}-1; index>=0; index--)); do
      [[ -n "${services[$index]}" ]] || continue
      read -r -a selected <<< "${services[$index]}"
      stack_command "${files[$index]}" start --wait --wait-timeout 900 "${selected[@]}" || {
        warn "Could not restart ${files[$index]} after backup."
        result=1
      }
    done
    exit "$result"
  }
  trap resume EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  while IFS= read -r file; do
    running="$(stack_command "$file" ps --status running --services)" || return
    files+=("$file")
    services+=("$(tr '\n' ' ' <<< "$running" | xargs)")
    if [[ "$file" == "$BASM_ROOT/docker-compose.yml" ]]; then
      record_stack_images "$file" "$BASM_ROOT/config/images.json" || return
      while IFS= read -r stopped; do
        case "$stopped" in erp-db|nextcloud-db|postal-db|'') ;; *) writers+=("$stopped") ;; esac
      done <<< "$running"
      if [[ ${#writers[@]} != 0 ]]; then
        stack_command "$file" stop --timeout 120 "${writers[@]}" || return
      fi
    else
      record_stack_images "$file" "${file%/*}/.basm-images.json" || return
      if [[ -n "$running" ]]; then stack_command "$file" stop --timeout 120 || return; fi
    fi
  done < <(deployment_stacks)
  dump_databases || return
  basm_stack stop --timeout 120 || return
  for file in "${files[@]}"; do
    active="$(stack_command "$file" ps --status running -q)" || return
    [[ -z "$active" ]] || fail "Services still running in $file; no snapshot was taken."
  done
  jq -n --arg root "$BASM_ROOT" --arg version "$(cat "$ROOT_DIR/VERSION")" \
    --arg mode "$DEPLOYMENT_MODE" '{format:2,root:$root,version:$version,mode:$mode}' \
    > "$BASM_ROOT/config/backup-manifest.json" || return
  # Include every module and the installed code, but never the repository itself.
  restic_command backup --host "$BASM_CONTAINER_PREFIX" --tag basm-v2 \
    --exclude "$BACKUP_LOCATION" --exclude "$BASM_ROOT/logs" "$BASM_ROOT"
)

initialize_repository() {
  check_backup_filesystem || return
  mkdir -p "$BACKUP_LOCATION" || return
  if [[ ! -f "$BACKUP_LOCATION/restic/config" ]]; then
    [[ ! -d "$BACKUP_LOCATION/restic" || -z "$(ls -A "$BACKUP_LOCATION/restic")" ]] ||
      fail "Backup repository is incomplete; refusing to initialize over it."
    restic_command init || return
  fi
  restic_command snapshots >/dev/null || return
  backup_filesystem > "$BASM_ROOT/config/backup-device" || return
  chmod 600 "$BASM_ROOT/config/backup-device"
  if [[ "$(stat -c %d "$BACKUP_LOCATION")" == "$(stat -c %d "$BASM_ROOT")" ]]; then
    warn "Backups share the data filesystem."
  fi
}

restore_deployment() {
  local snapshot="$1" target="$2" details
  [[ "$snapshot" =~ ^[a-f0-9]{8,64}$ ]] || fail "Use an explicit hexadecimal snapshot ID, not latest."
  details="$(restic_command snapshots --json "$snapshot")" || return
  jq -e --arg root "$BASM_ROOT" --arg host "$BASM_CONTAINER_PREFIX" \
    'length == 1 and .[0].hostname == $host and .[0].paths == [$root] and
    (.[0].tags | index("basm-v2")) != null' <<< "$details" >/dev/null ||
    fail "Not a unique complete snapshot for this BASM deployment."
  [[ "$target" == /* ]] || fail "Restore staging path must be absolute."
  target="$(realpath -m "$target")" || return
  case "$target/" in
    /|"$BASM_ROOT/"*|"$BACKUP_LOCATION/"*) fail "Restore outside live data and backups." ;;
  esac
  case "$BASM_ROOT/" in "$target/"*) fail "Staging cannot contain the live deployment." ;; esac
  case "$BACKUP_LOCATION/" in "$target/"*) fail "Staging cannot contain the backup repository." ;; esac
  [[ ! -e "$target" ]] || fail "Restore staging directory already exists."
  install -d -m 700 "$target" || return
  restic_command restore "$snapshot" --target "$target" --verify || return
  jq -e --arg root "$BASM_ROOT" '.format == 2 and .root == $root' \
    "$target$BASM_ROOT/config/backup-manifest.json" >/dev/null || fail "Restored backup manifest is invalid."
  [[ -s "$target$BASM_ROOT/config/images.json" && -f "$target$BASM_ROOT/config/basm.env" ]] ||
    fail "Restored deployment is missing its configuration or image lock."
  log "Verified restore staged at $target$BASM_ROOT; live data was not changed."
}

recovery_kit() {
  local target="$1"
  [[ "$target" == /* && -d "$target" ]] || fail "Choose an existing absolute external directory."
  target="$(realpath -e "$target")" || return
  [[ "$(stat -c %d "$target")" != "$(stat -c %d "$BASM_ROOT")" ]] ||
    fail "Save the recovery kit on another filesystem."
  [[ ! -e "$target/basm-recovery-kit" ]] || fail "Recovery kit already exists."
  install -d -m 700 "$target/basm-recovery-kit" || return
  cp -a "$BASM_ROOT/maintenance/." "$target/basm-recovery-kit/" || return
  install -m 600 "$BASM_ENV_FILE" "$target/basm-recovery-kit/basm.env" || return
  log "Recovery kit saved. Keep it private and independent of the server."
}
