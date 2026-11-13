#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

(
  source "$ROOT_DIR/modules/core.sh"
  BASM_MODULES='basm hotdog rustdesk lamp'
  ensure_module_dependencies
  [[ "$BASM_MODULES" == 'basm lamp hotdog rustdesk' ]]
  BASM_MODULES='basm rustdesk lamp hotdog'
  ensure_module_dependencies
  [[ "$BASM_MODULES" == 'basm rustdesk lamp hotdog' ]]
  BASM_MODULES='basm rustdesk hotdog'
  ensure_module_dependencies
  [[ "$BASM_MODULES" == 'basm rustdesk lamp hotdog' ]]
)

(
  source "$ROOT_DIR/modules/core.sh"
  BASM_ROOT="$TEST_DIR/routes"
  BASM_MODULES='basm lamp hotdog'
  BASM_CONTAINER_PREFIX=basm-test
  DEPLOYMENT_MODE=production
  BIND_ADDRESS=0.0.0.0
  PRIMARY_DOMAIN=acme.example
  COMPANY_NAME=Acme
  ERP_URL=erp.acme.example
  MAIL_URL=mail.acme.example
  CLOUD_URL=cloud.acme.example
  MAILBOX_HOSTNAME=mx.acme.example
  ADMIN_EMAIL=ops@acme.example
  mkdir -p "$BASM_ROOT/config"
  render_stack
  python3 - "$BASM_ROOT/config/traefik.yml" <<'PY'
import sys
import yaml

routes = yaml.safe_load(open(sys.argv[1]))["http"]
assert routes["routers"]["hotdog"]["rule"] == "Host(`hotdog.acme.example`)"
assert routes["routers"]["hotdog"]["entryPoints"] == ["websecure"]
assert routes["routers"]["hotdog"]["tls"] == {"certResolver": "letsencrypt"}
assert routes["services"]["hotdog-service"]["loadBalancer"]["servers"] == [
    {"url": "http://basm-hotdog-lamp:80"}
]
PY
)

(
  source "$ROOT_DIR/modules/lamp.sh"
  BASM_ROOT="$TEST_DIR/lamp"
  BASM_MODULES='basm lamp hotdog'
  BASM_CONTAINER_PREFIX=basm-test
  DEPLOYMENT_MODE=production
  PRIMARY_DOMAIN=acme.example
  BIND_ADDRESS=0.0.0.0
  MANAGEMENT_BIND_ADDRESS=127.0.0.1
  LAMP_PORT=18081
  mkdir -p "$BASM_ROOT/modules/lamp/www"
  printf 'existing LAMP site\n' > "$BASM_ROOT/modules/lamp/www/index.html"
  module_install
  grep -Fxq 'existing LAMP site' "$BASM_ROOT/modules/lamp/www/index.html"
  grep -Fq 'ServerName hotdog.acme.example' "$BASM_ROOT/modules/lamp/hotdog-vhost.conf"
  grep -Fq 'DocumentRoot /var/www/hotdog/current' "$BASM_ROOT/modules/lamp/hotdog-vhost.conf"
  grep -Fq 'ErrorDocument 404 /404.html' "$BASM_ROOT/modules/lamp/hotdog-vhost.conf"
  grep -Fq 'FilesMatch "^\.hotdog-cms-"' "$BASM_ROOT/modules/lamp/hotdog-vhost.conf"
  python3 - "$BASM_ROOT/modules/lamp/docker-compose.yml" <<'PY'
import sys
import yaml

compose = yaml.safe_load(open(sys.argv[1]))
volumes = compose["services"]["lamp"]["volumes"]
assert "./www:/var/www/html" in volumes
assert "./hotdog:/var/www/hotdog:ro" in volumes
assert "./hotdog-vhost.conf:/etc/apache2/sites-enabled/001-hotdog.conf:ro" in volumes
assert compose["services"]["lamp"]["networks"]["basm-net"]["aliases"] == ["basm-hotdog-lamp"]
assert compose["networks"]["basm-net"] == {"external": True, "name": "basm-test-net"}
PY
)

(
  source "$ROOT_DIR/modules/hotdog.sh"
  BASM_ROOT="$TEST_DIR/install"
  BASM_MODULES='basm lamp hotdog'
  PRIMARY_DOMAIN=acme.example
  DEPLOYMENT_MODE=production
  dpkg() { printf 'amd64\n'; }
  curl() {
    local destination=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi
    done
    cat > "$destination" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == new && "$2" == site ]]; then
  mkdir site
  printf 'url: https://example.org\n' > site/site.yaml
else
  exit 2
fi
STUB
  }
  sha256sum() {
    if [[ "${1:-}" == --check ]]; then return 0; fi
    command sha256sum "$@"
  }
  module_install
  SITE_DIR="$BASM_ROOT/modules/hotdog/site"
  BINARY="$BASM_ROOT/modules/hotdog/hotdog-cms"
  [[ -x "$BINARY" && -f "$SITE_DIR/site.yaml" ]]
  grep -Fxq "    path: '$BASM_ROOT/modules/lamp/hotdog/current'" "$SITE_DIR/publish.yaml"
  [[ "$(stat -c '%a' "$SITE_DIR/publish.yaml")" == 640 ]]
  printf 'targets:\n  preserved: {}\n' > "$SITE_DIR/publish.yaml"
  module_install
  grep -Fq 'preserved: {}' "$SITE_DIR/publish.yaml"
)

(
  unset -f sha256sum
  source "$ROOT_DIR/modules/hotdog.sh"
  BASM_ROOT="$TEST_DIR/rejected"
  BASM_MODULES='basm lamp hotdog'
  PRIMARY_DOMAIN=acme.example
  dpkg() { printf 'amd64\n'; }
  curl() {
    local destination=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then destination="$2"; shift 2; else shift; fi
    done
    printf 'unverified binary\n' > "$destination"
  }
  if (module_install) >/dev/null 2>&1; then
    printf 'HotDog CMS accepted an unverified download.\n' >&2
    exit 1
  fi
  [[ ! -e "$BASM_ROOT/modules/hotdog/hotdog-cms" ]]
  [[ -z "$(find "$BASM_ROOT/modules/hotdog" -name '.hotdog-cms.*' -print -quit)" ]]
)

printf 'HotDog dependencies, isolated LAMP publishing, verified installation and preservation passed.\n'
