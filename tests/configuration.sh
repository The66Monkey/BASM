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
WEB_PROTOCOL=https
IP_MODE=static
BACKUP_LOCATION="$BASM_ROOT/backups"
for variable in DB_ROOT_PASSWORD ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD RESTIC_PASSWORD; do
  printf -v "$variable" '%s' test-only-placeholder
  export "$variable"
done
for modules in 'basm' 'basm fluxer'; do
  BASM_MODULES="$modules"
  ensure_port_defaults
  write_env_file
  render_stack
  export MAIL_URL WEB_PROTOCOL PRIMARY_DOMAIN ADMIN_EMAIL COMPANY_NAME MAILBOX_HOSTNAME
  /usr/bin/python3 - "$ROOT_DIR" "$BASM_ROOT" "$modules" "$SMTP_BIND_ADDRESS" "$MAILBOX_BIND_ADDRESS" "$SMTP_PORT" "$MAILBOX_SUBMISSION_PORT" "$MAILBOX_IMAPS_PORT" <<'PY'
import importlib.util
import json
import pathlib
import sys

root, deployment, modules, smtp_bind, mailbox_bind, smtp_port, submission_port, imaps_port = sys.argv[1:]
spec = importlib.util.spec_from_file_location("routes", f"{root}/templates/render-routes.py")
routes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(routes)
with open(f"{deployment}/config/traefik.yml") as file:
    config = routes.yaml.load(file, Loader=routes.UniqueLoader)
with open(f"{deployment}/config/traefik-static.yml") as file:
    static_config = routes.yaml.safe_load(file)
assert static_config["providers"]["file"]["watch"] is True
assert static_config["entryPoints"]["websecure"]["proxyProtocol"]["trustedIPs"] == []
http = config["http"]
expected = {"home", "erp", "mail", "cloud", "http-to-https"}
if "fluxer" in modules.split():
    expected.add("fluxer")
assert set(http["routers"]) == expected, (set(http["routers"]), expected)
for router in http["routers"].values():
    assert router["service"] in http["services"] or router["service"] == "noop@internal"
    assert all(name in http["middlewares"] for name in router.get("middlewares", []))
assert http["routers"]["mail"]["middlewares"] == ["mail-canonical"]
assert http["routers"]["mail"]["service"] == "noop@internal"
assert http["middlewares"]["mail-canonical"]["redirectRegex"]["replacement"] == (
    "https://mx.example.com/$1"
)
assert config["tcp"]["routers"]["mailbox"]["rule"] == "HostSNI(`mx.example.com`)", config["tcp"]["routers"]
assert config["tcp"]["routers"]["mailbox-service-hosts"]["rule"] == (
    "HostSNI(`autoconfig.example.com`) || HostSNI(`autodiscover.example.com`) || "
    "HostSNI(`mta-sts.example.com`) || HostSNI(`ua-auto-config.example.com`)"
), config["tcp"]["routers"]
assert config["tcp"]["routers"]["mailbox"]["tls"] == {"passthrough": True}, config["tcp"]["routers"]
assert config["tcp"]["routers"]["mailbox-service-hosts"]["tls"] == {"passthrough": True}
assert config["tcp"]["services"]["mailbox-service"]["loadBalancer"]["servers"] == [
    {"address": "stalwart-mail-proxy:8443"}
]
assert "serversTransport" not in config["tcp"]["services"]["mailbox-service"]
assert config["tcp"]["services"]["mailbox-service"]["loadBalancer"]["serversTransport"] == "mailbox-proxy"
assert config["tcp"]["serversTransports"]["mailbox-proxy"]["proxyProtocol"]["version"] == 2
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
assert "ports" not in services["homepage"]
assert services["homepage"]["volumes"] == [f"{deployment}/home:/usr/share/nginx/html:ro"]
assert not any("postal" in service for service in services)
assert services["stalwart-mail"]["image"] == "stalwartlabs/stalwart:v1"
assert f"{deployment}/data/stalwart:/var/lib/stalwart" in services["stalwart-mail"]["volumes"]
assert f"{deployment}/config/stalwart:/etc/stalwart" in services["stalwart-mail"]["volumes"]
assert services["traefik"]["networks"]["basm-mail-proxy"]["ipv4_address"] == "172.31.255.2"
assert services["stalwart-mail"]["networks"]["basm-mail-proxy"]["ipv4_address"] == "172.31.255.3"
assert services["stalwart-mail"]["networks"]["basm-mail-proxy"]["aliases"] == ["stalwart-mail-proxy"]
assert compose["networks"]["basm-mail-proxy"]["internal"] is True
assert compose["networks"]["basm-mail-proxy"]["ipam"]["config"] == [{"subnet": "172.31.255.0/29"}]
assert f"{smtp_bind}:{smtp_port}:25" in services["stalwart-mail"]["ports"], services["stalwart-mail"]["ports"]
assert f"{mailbox_bind}:{submission_port}:465" in services["stalwart-mail"]["ports"], services["stalwart-mail"]["ports"]
assert f"{mailbox_bind}:{imaps_port}:993" in services["stalwart-mail"]["ports"], services["stalwart-mail"]["ports"]
assert config["http"]["routers"]["home"]["rule"] == "Host(`example.com`)"
assert config["http"]["services"]["home-service"]["loadBalancer"]["servers"] == [{"url": "http://homepage:80"}]
PY
  if [[ -n "${COMPOSE_BIN:-}" ]]; then
    "$COMPOSE_BIN" --env-file "$BASM_ENV_FILE" -f "$BASM_ROOT/docker-compose.yml" config --format json > "$TEMP/compose.json"
  else
    basm_compose --env-file "$BASM_ENV_FILE" -f "$BASM_ROOT/docker-compose.yml" config --format json > "$TEMP/compose.json"
  fi
  jq -e '.services.nextcloud.image == .services["nextcloud-cron"].image and
    .services["erpnext-backend"].depends_on["erpnext-create-site"].condition == "service_completed_successfully"' "$TEMP/compose.json" >/dev/null
done
printf '192.0.2.245\n' > "$BASM_ROOT/config/traefik-edge-ip"
render_stack
python3 - "$BASM_ROOT/config/traefik-static.yml" <<'PY'
import sys
from pathlib import Path
import yaml

config = yaml.safe_load(Path(sys.argv[1]).read_text())
expected = ["192.0.2.245/32"]
assert config["entryPoints"]["websecure"]["proxyProtocol"]["trustedIPs"] == expected
assert config["entryPoints"]["websecure"]["forwardedHeaders"]["trustedIPs"] == expected
PY
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
path.write_text('POSTAL_DB_PASSWORD="legacy"\nPOSTAL_WEB_PROTOCOL="https"\nWEB_PROTOCOL="https"\n')
legacy_settings = settings.read_environment(path)
assert legacy_settings["WEB_PROTOCOL"] == "https"
assert legacy_settings["POSTAL_DB_PASSWORD"] == "legacy"
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
