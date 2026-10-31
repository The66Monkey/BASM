#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core.sh"

fluxer_env_value() {
  local key="$1" file="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

fluxer_set_env() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

fluxer_merge_env_example() {
  local current="$1" example="$2" output="$3"
  awk '
    FNR == NR {
      if ($0 ~ /^[A-Z][A-Z0-9_]*=/) {
        key = $0
        sub(/=.*/, "", key)
        values[key] = substr($0, length(key) + 2)
      }
      next
    }
    /^[A-Z][A-Z0-9_]*=/ {
      key = $0
      sub(/=.*/, "", key)
      if (key in values) {
        print key "=" values[key]
        next
      }
    }
    { print }
  ' "$current" "$example" > "$output"
}

fluxer_fetch_bundle() {
  local destination="$1" archive
  archive="$destination/fluxer-compose.tar.gz"
  if [[ -n "${FLUXER_COMPOSE_BUNDLE:-}" ]]; then
    cp "$FLUXER_COMPOSE_BUNDLE" "$archive" || return
  else
    curl -fsSL --retry 3 https://fluxer.dev/compose/latest -o "$archive" || return
  fi
  if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    warn "Fluxer release archive contains an unsafe path."
    return 1
  fi
  tar -xzf "$archive" -C "$destination" || return
  [[ -s "$destination/docker-compose.yml" && -s "$destination/docker-compose.proxy.yml" && -s "$destination/.env.example" ]]
}

fluxer_install_bundle() {
  local module_dir="$1" temporary_dir="$2" data_dir
  fluxer_fetch_bundle "$temporary_dir" || fail "Could not download or unpack the official Fluxer Compose bundle."
  rm -f "$temporary_dir/fluxer-compose.tar.gz"
  cp -a "$temporary_dir/." "$module_dir/" || fail "Could not install the Fluxer Compose bundle."
  ensure_dir "$BASM_ROOT/data/fluxer"
  for data_dir in edge-data edge-config postgres-data valkey-data nats-data meilisearch-data seaweedfs-data media-proxy-tmp db-backups; do
    ensure_dir "$BASM_ROOT/data/fluxer/$data_dir"
  done
}

fluxer_generate_vapid_keys() {
  local key_file="$1" public_key private_key
  openssl ecparam -name prime256v1 -genkey -noout -out "$key_file" || return
  public_key="$(openssl ec -in "$key_file" -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr '/+' '_-' | tr -d '=\n')" || return
  private_key="$(openssl ec -in "$key_file" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64 | tr '/+' '_-' | tr -d '=\n')" || return
  printf '%s\n%s\n' "$public_key" "$private_key"
}

fluxer_configure_env() {
  local module_dir="$1" env_file="$1/.env" temporary_env="$1/.env.new"
  local key value vapid_values key_file public_scheme public_origin public_port

  if [[ -f "$env_file" ]]; then
    fluxer_merge_env_example "$env_file" "$module_dir/.env.example" "$temporary_env" || return
    mv "$temporary_env" "$env_file" || return
  else
    cp "$module_dir/.env.example" "$env_file" || return
  fi

  ensure_port_defaults
  public_scheme=https
  public_origin="https://$FLUXER_DOMAIN:$HTTPS_PORT"
  public_port="$HTTPS_PORT"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    public_scheme=http
    public_origin="http://$FLUXER_DOMAIN:$HTTP_PORT"
    public_port="$HTTP_PORT"
  fi
  fluxer_set_env FLUXER_SETTINGS_LOADED true "$env_file"
  fluxer_set_env FLUXER_DOMAIN "$FLUXER_DOMAIN" "$env_file"
  fluxer_set_env FLUXER_PUBLIC_SCHEME "$public_scheme" "$env_file"
  fluxer_set_env FLUXER_PUBLIC_ORIGIN "$public_origin" "$env_file"
  fluxer_set_env FLUXER_PUBLIC_PORT "$public_port" "$env_file"
  fluxer_set_env FLUXER_LIVEKIT_TCP_PORT "$FLUXER_LIVEKIT_TCP_PORT" "$env_file"
  fluxer_set_env FLUXER_LIVEKIT_UDP_PORT "$FLUXER_LIVEKIT_UDP_PORT" "$env_file"
  fluxer_set_env COMPOSE_PROJECT_NAME "${BASM_CONTAINER_PREFIX:-basm}-fluxer" "$env_file"
  fluxer_set_env COMPOSE_FILE 'docker-compose.yml:docker-compose.proxy.yml:docker-compose.basm.yml' "$env_file"
  fluxer_set_env BASM_ROOT "$BASM_ROOT" "$env_file"
  fluxer_set_env BASM_CONTAINER_PREFIX "${BASM_CONTAINER_PREFIX:-basm}" "$env_file"
  fluxer_set_env BIND_ADDRESS "$BIND_ADDRESS" "$env_file"
  if [[ "${DEPLOYMENT_MODE:-production}" == local ]]; then
    fluxer_set_env FLUXER_LIVEKIT_USE_EXTERNAL_IP false "$env_file"
    fluxer_set_env FLUXER_LIVEKIT_NODE_IP "$BIND_ADDRESS" "$env_file"
  fi

  for key in FLUXER_SETUP_TOKEN POSTGRES_PASSWORD MEILI_MASTER_KEY FLUXER_S3_SECRET_KEY LIVEKIT_API_SECRET \
    FLUXER_SUDO_MODE_SECRET FLUXER_CONNECTION_INITIATION_SECRET FLUXER_PROFILE_PSEUDONYM_SECRET \
    FLUXER_GATEWAY_RPC_AUTH_TOKEN FLUXER_ERLANG_COOKIE FLUXER_MEDIA_PROXY_SECRET_KEY \
    FLUXER_ADMIN_SECRET_KEY_BASE FLUXER_ADMIN_OAUTH_CLIENT_SECRET; do
    value="$(fluxer_env_value "$key" "$env_file")"
    if [[ -z "$value" ]]; then
      value="$(generate_secret)" || return
      fluxer_set_env "$key" "$value" "$env_file" || return
    fi
  done

  value="$(fluxer_env_value FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64 "$env_file")"
  if [[ -z "$value" ]]; then
    value="$(openssl rand -base64 32 | tr -d '\n')" || return
    fluxer_set_env FLUXER_MEDIA_PROXY_UPLOAD_RELAY_SECRET_BASE64 "$value" "$env_file" || return
  fi

  value="$(fluxer_env_value FLUXER_ACTIVITYPUB_SIGNING_KEY_BASE64 "$env_file")"
  if [[ -z "$value" ]]; then
    value="$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -outform DER 2>/dev/null | base64 | tr -d '\n')" || return
    fluxer_set_env FLUXER_ACTIVITYPUB_SIGNING_KEY_BASE64 "$value" "$env_file" || return
  fi

  if [[ -z "$(fluxer_env_value FLUXER_VAPID_PUBLIC_KEY "$env_file")" || -z "$(fluxer_env_value FLUXER_VAPID_PRIVATE_KEY "$env_file")" ]]; then
    key_file="$module_dir/.vapid-key.pem"
    umask 077
    vapid_values="$(fluxer_generate_vapid_keys "$key_file")" || return
    rm -f "$key_file"
    fluxer_set_env FLUXER_VAPID_PUBLIC_KEY "${vapid_values%%$'\n'*}" "$env_file" || return
    fluxer_set_env FLUXER_VAPID_PRIVATE_KEY "${vapid_values#*$'\n'}" "$env_file" || return
  fi

  chmod 600 "$env_file"
}

fluxer_write_basm_overlay() {
  local module_dir="$1"
  cat > "$module_dir/docker-compose.basm.yml" <<'EOF'
services:
  edge:
    ports: !override []
    networks:
      fluxer: {}
      basm-net:
        aliases:
          - fluxer-edge
  livekit:
    ports: !override
      - "${BIND_ADDRESS}:${FLUXER_LIVEKIT_TCP_PORT}:${FLUXER_LIVEKIT_TCP_PORT}"
      - "${BIND_ADDRESS}:${FLUXER_LIVEKIT_UDP_PORT}:${FLUXER_LIVEKIT_UDP_PORT}/udp"
  fluxer-db-backup:
    image: ${FLUXER_POSTGRES_IMAGE:-postgres:16-alpine}
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c"]
    command:
      - >-
        set -eu;
        umask 077;
        while true; do
          dump="/backups/fluxer-$$(date -u +%Y%m%dT%H%M%SZ).sql";
          pg_dumpall -h postgres -U "$${FLUXER_POSTGRES_USERNAME:-fluxer}" > "$$dump.tmp";
          mv "$$dump.tmp" "$$dump";
          find /backups -type f -name 'fluxer-*.sql' -mtime +7 -delete;
          sleep 86400;
        done
    environment:
      PGPASSWORD: ${POSTGRES_PASSWORD:?Fluxer PostgreSQL password is required}
    volumes:
      - fluxer-db-backups:/backups
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - fluxer

networks:
  basm-net:
    name: ${BASM_CONTAINER_PREFIX}-net
    external: true

volumes:
  edge-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/edge-data
  edge-config:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/edge-config
  postgres-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/postgres-data
  valkey-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/valkey-data
  nats-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/nats-data
  meilisearch-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/meilisearch-data
  seaweedfs-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/seaweedfs-data
  media-proxy-tmp:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/media-proxy-tmp
  fluxer-db-backups:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${BASM_ROOT}/data/fluxer/db-backups
EOF
  chmod 600 "$module_dir/docker-compose.basm.yml"
}

module_install() {
  local module_dir="${1:-$BASM_ROOT/modules/fluxer}" temporary_dir
  log "Installing Fluxer module"
  ensure_port_defaults
  ensure_dir "$module_dir" || return
  if [[ ! -s "$module_dir/docker-compose.yml" ]]; then
    temporary_dir="$(mktemp -d)" || return
    fluxer_install_bundle "$module_dir" "$temporary_dir"
    rm -rf "$temporary_dir"
  else
    local data_dir
    ensure_dir "$BASM_ROOT/data/fluxer"
    for data_dir in edge-data edge-config postgres-data valkey-data nats-data meilisearch-data seaweedfs-data media-proxy-tmp db-backups; do
      ensure_dir "$BASM_ROOT/data/fluxer/$data_dir"
    done
  fi
  fluxer_configure_env "$module_dir" || fail "Could not configure Fluxer secrets and settings."
  fluxer_write_basm_overlay "$module_dir"
  log "Fluxer Compose bundle configured for BASM Traefik"
}

module_start() {
  start_module_stack fluxer
}

module_update() {
  local module_dir="${1:-$BASM_ROOT/modules/fluxer}" temporary_dir
  [[ -d "$module_dir" ]] || return 0
  temporary_dir="$(mktemp -d)" || return
  fluxer_install_bundle "$module_dir" "$temporary_dir"
  fluxer_configure_env "$module_dir" || fail "Could not migrate Fluxer settings to the latest release."
  fluxer_write_basm_overlay "$module_dir"
  rm -rf "$temporary_dir"
  log "Fluxer Compose bundle updated"
}
