#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/modules/core.sh"
source "$ROOT_DIR/modules/releases.sh"
source "$ROOT_DIR/modules/backup.sh"

SOURCE_ROOT="$TEST_DIR/release"
SOURCE_DIR="$SOURCE_ROOT/erpnext-apps/basm_rot_rut"
BASM_ROOT="$TEST_DIR/deployment"
BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
mkdir -p "$SOURCE_DIR" "$BASM_ROOT/config"
: > "$BASM_ROOT/docker-compose.yml"
printf 'FROM ${BASE_IMAGE}\n' > "$SOURCE_DIR/Dockerfile"
printf 'source-v1\n' > "$SOURCE_DIR/app.py"
printf 'COMPANY_NAME="Image test"\nERP_IMAGE="frappe/erpnext:v16"\nERP_BASE_IMAGE=""\n' > "$BASM_ENV_FILE"
chmod 600 "$BASM_ENV_FILE"

BUILT_IMAGES=()
BUILD_COUNT=0
DOCKER_LOG="$TEST_DIR/docker.log"
docker() {
  printf '%s\n' "$*" >> "$DOCKER_LOG"
  case "$1 $2" in
    "pull frappe/erpnext:v16") return 0 ;;
    "image inspect")
      local format="" target="" argument
      shift 2
      while (($#)); do
        argument="$1"
        if [[ "$argument" == --format ]]; then
          format="$2"
          shift 2
        else
          target="$argument"
          shift
        fi
      done
      if [[ "$format" == *RepoDigests* ]]; then
        if [[ "$target" == frappe/erpnext:v16 ]]; then
          printf '["frappe/erpnext@sha256:%064d"]\n' 0
        else
          printf '["nginx:1.30.6-alpine@sha256:%064d"]\n' 0
        fi
        return 0
      fi
      if [[ "$format" == *".Id"* ]]; then
        printf 'sha256:%064d\n' 1
        return 0
      fi
      local built
      for built in "${BUILT_IMAGES[@]}"; do
        [[ "$built" != "$target" ]] || return 0
      done
      return 1
      ;;
    "build --pull")
      local tag=""
      while (($#)); do
        if [[ "$1" == --tag ]]; then
          tag="$2"
          shift 2
        else
          shift
        fi
      done
      [[ -n "$tag" ]] || return 1
      BUILT_IMAGES+=("$tag")
      ((BUILD_COUNT += 1))
      ;;
    inspect*) printf 'sha256:%064d\n' 1 ;;
    *) printf 'Unexpected docker invocation: %s\n' "$*" >&2; return 1 ;;
  esac
}

ERP_ROT_RUT=yes
ERP_IMAGE=frappe/erpnext:v16
ERP_BASE_IMAGE=""
prepare_erp_rot_rut_image "$SOURCE_ROOT" refresh
LOCAL_IMAGE="$ERP_IMAGE"
[[ "$LOCAL_IMAGE" =~ ^basm-erpnext:v16-rot-rut-[a-f0-9]{64}$ ]]
[[ "$ERP_BASE_IMAGE" == "frappe/erpnext@sha256:$(printf '%064d' 0)" ]]
validate_erp_configuration
[[ "$BUILD_COUNT" == 1 ]]
prepare_erp_rot_rut_image "$SOURCE_ROOT" refresh
[[ "$ERP_IMAGE" == "$LOCAL_IMAGE" && "$BUILD_COUNT" == 1 ]]

write_erp_image_settings
grep -Fqx "ERP_IMAGE=\"$LOCAL_IMAGE\"" "$BASM_ENV_FILE"
grep -Fqx "ERP_BASE_IMAGE=\"$ERP_BASE_IMAGE\"" "$BASM_ENV_FILE"
grep -Fqx 'COMPANY_NAME="Image test"' "$BASM_ENV_FILE"
[[ "$(stat -c '%a' "$BASM_ENV_FILE")" == 600 ]]

pull_count="$(grep -Fc 'pull frappe/erpnext:v16' "$DOCKER_LOG")"
BUILT_IMAGES=()
ERP_IMAGE="$LOCAL_IMAGE"
prepare_erp_rot_rut_image "$SOURCE_ROOT" restore
[[ "$ERP_IMAGE" == "$LOCAL_IMAGE" && "$BUILD_COUNT" == 2 ]]
[[ "$(grep -Fc 'pull frappe/erpnext:v16' "$DOCKER_LOG")" == "$pull_count" ]]

COMPOSE_CONFIG="$(jq -nc --arg local "$LOCAL_IMAGE" \
  '{services:{"erpnext-backend":{image:$local},homepage:{image:"nginx:1.30.6-alpine"}}}')"
PULL_LOG="$TEST_DIR/pulls.log"
IMAGE_LOCK="$TEST_DIR/images.json"
: > "$IMAGE_LOCK"
basm_compose() {
  case " $* " in
    *" config --format json "*) printf '%s\n' "$COMPOSE_CONFIG" ;;
    *" pull --quiet "*) printf '%s\n' "$*" >> "$PULL_LOG" ;;
    *) printf 'Unexpected Compose invocation: %s\n' "$*" >&2; return 1 ;;
  esac
}
pull_deployment_images "$BASM_ROOT/docker-compose.yml" "$BASM_ENV_FILE" "$IMAGE_LOCK"
grep -Fq 'homepage' "$PULL_LOG"
! grep -Fq 'erpnext-backend' "$PULL_LOG"
grep -Fq -- "-f $IMAGE_LOCK" "$PULL_LOG"

configuration="$(jq -nc --arg local "$LOCAL_IMAGE" \
  '{services:{"erpnext-backend":{image:$local},homepage:{image:"nginx:1.30.6-alpine"}}}')"
resolve_release_images "$configuration" "$TEST_DIR/images.json"
EXPECTED_REMOTE_IMAGE="nginx:1.30.6-alpine@sha256:$(printf '%064d' 0)"
jq -e --arg local "$LOCAL_IMAGE" --arg remote "$EXPECTED_REMOTE_IMAGE" \
  '.services["erpnext-backend"].image == $local and .services.homepage.image == $remote' \
  "$TEST_DIR/images.json" >/dev/null

RECORD_CONFIG="$(jq -nc --arg local "$LOCAL_IMAGE" \
  '{services:{"erpnext-backend":{image:$local}}}')"
stack_command() {
  case "$2" in
    config) printf '%s\n' "$RECORD_CONFIG" ;;
    ps) printf 'rot-rut-container\n' ;;
    *) return 1 ;;
  esac
}
record_stack_images "$BASM_ROOT/docker-compose.yml" "$TEST_DIR/recorded-images.json"
jq -e --arg local "$LOCAL_IMAGE" \
  '.services["erpnext-backend"].image == $local' "$TEST_DIR/recorded-images.json" >/dev/null

printf 'source-v2\n' > "$SOURCE_DIR/app.py"
prepare_erp_rot_rut_image "$SOURCE_ROOT" refresh
[[ "$ERP_IMAGE" != "$LOCAL_IMAGE" && "$BUILD_COUNT" == 3 ]]

printf 'local image build, pinning, pull exclusion, and recovery manifest checks passed.\n'
