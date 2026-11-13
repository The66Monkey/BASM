#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

HOTDOG_VERSION="0.11.0"

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/hotdog}"
  local asset checksum url temporary site_dir target_path yaml_target
  local arch

  case "$(dpkg --print-architecture)" in
    amd64) arch=amd64; checksum=55a620e7fae9615b5230153b6d7d4ed0ff3915a983a6a43016a9a23f5e433e85 ;;
    arm64) arch=arm64; checksum=5b5f68d47972d5879d9460536d078d836eb80080c5bda4c204b6bf03984ae951 ;;
    *) fail "HotDog CMS ${HOTDOG_VERSION} does not provide a binary for this architecture." ;;
  esac

  asset="hotdog-cms-linux-$arch"
  url="https://git.coffeylabs.org/coffey-labs/hotdog-cms/releases/download/v${HOTDOG_VERSION}/${asset}"
  ensure_dir "$module_dir" || return
  local binary="$module_dir/hotdog-cms"
  [[ ! -L "$binary" ]] || fail "HotDog CMS binary cannot be a symbolic link."
  if [[ -e "$binary" ]]; then
    [[ -f "$binary" ]] || fail "HotDog CMS binary path must be a regular file."
  fi
  if [[ ! -f "$binary" ]] || ! printf '%s  %s\n' "$checksum" "$binary" | sha256sum --check --status; then
    temporary="$(mktemp "$module_dir/.hotdog-cms.XXXXXX")" || return
    if ! curl -fLsS --retry 3 -o "$temporary" "$url" ||
      ! printf '%s  %s\n' "$checksum" "$temporary" | sha256sum --check --status; then
      rm -f "$temporary"
      fail "Could not download and verify HotDog CMS ${HOTDOG_VERSION}."
    fi
    chmod 755 "$temporary" || { rm -f "$temporary"; return 1; }
    mv -f "$temporary" "$binary" || { rm -f "$temporary"; return 1; }
  fi
  chmod 755 "$binary" || return

  site_dir="$module_dir/site"
  [[ ! -L "$site_dir" ]] || fail "HotDog site directory cannot be a symbolic link."
  if [[ ! -e "$site_dir" ]]; then
    (cd "$module_dir" && "$binary" new site) || return
  fi
  [[ -d "$site_dir" && -f "$site_dir/site.yaml" && ! -L "$site_dir/site.yaml" ]] ||
    fail "HotDog site directory is incomplete; preserve it and restore site.yaml."

  local publish_file="$site_dir/publish.yaml"
  [[ ! -L "$publish_file" ]] || fail "HotDog publishing configuration cannot be a symbolic link."
  if [[ -e "$publish_file" ]]; then
    [[ -f "$publish_file" ]] || fail "HotDog publishing configuration must be a regular file."
  fi
  if [[ ! -e "$publish_file" ]]; then
    target_path="$BASM_ROOT/modules/lamp/hotdog/current"
    yaml_target="${target_path//\'/\'\'}"
    cat > "$publish_file" <<EOF || return
targets:
  live:
    type: dir
    path: '$yaml_target'
EOF
    chmod 640 "$publish_file" || return
  fi

  log "HotDog CMS ${HOTDOG_VERSION} installed; edit $site_dir and publish with $binary publish live"
}
