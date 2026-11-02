#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
source "$ROOT_DIR/config/defaults.env"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BASM_ROOT="$TEMP/deployment"
BASM_ENV_FILE="$BASM_ROOT/config/basm.env"
mkdir -p "$BASM_ROOT/config"
BASM_CONTAINER_PREFIX=basm-test
DEPLOYMENT_MODE=production
BIND_ADDRESS=0.0.0.0
SMTP_BIND_ADDRESS=127.0.0.1
POSTAL_WEB_PROTOCOL=https
IP_MODE=static
BACKUP_LOCATION="$BASM_ROOT/backups"
for variable in DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD POSTAL_DB_PASSWORD \
  POSTAL_ADMIN_PASSWORD POSTAL_RAILS_SECRET NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD; do
  printf -v "$variable" '%s' test-only-placeholder
  export "$variable"
done
for modules in 'basm' 'basm fluxer'; do
  BASM_MODULES="$modules"
  ensure_port_defaults
  write_env_file
  render_stack
  export MAIL_URL POSTAL_WEB_PROTOCOL PRIMARY_DOMAIN ADMIN_EMAIL COMPANY_NAME
  render_postal_config
  /usr/bin/python3 - "$ROOT_DIR" "$BASM_ROOT" "$modules" <<'PY'
import importlib.util
import json
import pathlib
import sys

root, deployment, modules = sys.argv[1:]
spec = importlib.util.spec_from_file_location("routes", f"{root}/templates/render-routes.py")
routes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes)
with open(f"{deployment}/config/traefik.yml") as file:
    config = routes.yaml.load(file, Loader=routes.UniqueLoader)["http"]
expected = {"erp", "mail", "cloud", "http-to-https"}
if "fluxer" in modules.split():
    expected.add("fluxer")
assert set(config["routers"]) == expected
for router in config["routers"].values():
    assert router["service"] in config["services"] or router["service"] == "noop@internal"
    assert all(name in config["middlewares"] for name in router.get("middlewares", []))
try:
    routes.yaml.load("http:\n  routers: {}\n  routers: {}\n", Loader=routes.UniqueLoader)
except ValueError:
    pass
else:
    raise AssertionError("Duplicate routing keys accepted")
with open(f"{deployment}/docker-compose.yml") as file:
    compose = routes.yaml.safe_load(file)
services = compose["services"]
assert "restic-backup" not in services and "db-backup" not in services
assert services["nextcloud"]["image"] == services["nextcloud-cron"]["image"]
assert all(service["logging"]["driver"] == "local" for service in services.values())
assert all(not service["image"].endswith((":latest", ":apache")) for service in services.values())
assert all("docker.sock" not in str(service) for service in services.values())
PY
  if [[ -n "${COMPOSE_BIN:-}" ]]; then
    "$COMPOSE_BIN" --env-file "$BASM_ENV_FILE" -f "$BASM_ROOT/docker-compose.yml" config --format json > "$TEMP/compose.json"
  else
    basm_compose --env-file "$BASM_ENV_FILE" -f "$BASM_ROOT/docker-compose.yml" config --format json > "$TEMP/compose.json"
  fi
  jq -e '.services.nextcloud.image == .services["nextcloud-cron"].image and
    .services["erpnext-backend"].depends_on["erpnext-create-site"].condition == "service_completed_successfully"' "$TEMP/compose.json" >/dev/null
done
mkdir -p "$TEMP/candidate/config"
BASM_RENDER_DIR="$TEMP/candidate" render_postal_config
cmp "$BASM_ROOT/config/postal/signing.key" "$TEMP/candidate/config/postal/signing.key"
/usr/bin/python3 - "$ROOT_DIR" "$TEMP" <<'PY'
import importlib.util
import pathlib
import sys

root, temporary = sys.argv[1:]
spec = importlib.util.spec_from_file_location("settings", f"{root}/templates/read-environment.py")
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)
path = pathlib.Path(temporary, "settings.env")
path.write_text('COMPANY_NAME="A business $(touch /not-executed)"\n')
assert settings.read_environment(path)["COMPANY_NAME"].endswith("$(touch /not-executed)")
for content in ('BAD_KEY=x\n', 'BASM_ROOT=a\nBASM_ROOT=b\n', 'COMPANY_NAME="unterminated\n'):
    path.write_text(content)
    try:
        settings.read_environment(path)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid settings accepted")
PY
printf 'Structural route, Compose and data-only settings checks passed.\n'
