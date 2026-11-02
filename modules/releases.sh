#!/usr/bin/env bash

scheduled_update_window() {
  local hour="$1"
  [[ "$hour" =~ ^[0-9]{2}$ ]] && (( 10#$hour < 6 ))
}

image_version() {
  local service="$1" image="$2" version metadata key
  case "$service" in
    nextcloud) key=NEXTCLOUD_VERSION ;;
    erp-db|nextcloud-db|postal-db) key=MARIADB_VERSION ;;
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
  for service in nextcloud erp-db nextcloud-db postal-db; do
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
  for service in nextcloud erp-db nextcloud-db postal-db; do
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
  ROOT_DIR="$release" BASM_RENDER_DIR="$stage" render_postal_config || return
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
  install -m 755 "$release/templates/erpnext-create-site.sh" "$BASM_ROOT/config/erpnext-create-site.sh" || return
  cp -p "$stage/config/postal/postal.yml" "$BASM_ROOT/config/postal/postal.yml" || return
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
  rm "$BASM_ROOT/config/update-in-progress" || return
  log "BASM update completed. The automatic schedule remains January 1 and July 1 at 03:00."
)
