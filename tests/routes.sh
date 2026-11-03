#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import tempfile

renderer = Path(sys.argv[1], "templates/render-routes.py")
base = {"http": {"routers": {"home": {"service": "home"}}, "services": {"home": {}}}}
with tempfile.TemporaryDirectory() as directory:
    custom = Path(directory, "custom.yml")

    def render(domain="", entrypoint="websecure"):
        return subprocess.run(
            [sys.executable, str(renderer), domain, "29461", entrypoint, str(custom)],
            input=json.dumps(base), text=True, capture_output=True,
        )

    assert json.loads(render().stdout) == base
    additions = {"http": {
        "routers": {"external-chat": {"rule": "Host(`chat.example.com`)", "service": "external-chat"}},
        "services": {"external-chat": {"loadBalancer": {"servers": [{"url": "https://192.0.2.10"}]}}},
        "serversTransports": {"external-chat": {"serverName": "chat.example.com"}},
    }}
    custom.write_text(json.dumps(additions))
    for domain, entrypoint in [("", "websecure"), ("fluxer.example.com", "websecure"), ("fluxer.example.com", "web")]:
        result = render(domain, entrypoint)
        assert result.returncode == 0, result.stderr
        merged = json.loads(result.stdout)["http"]
        assert merged["routers"]["home"] == base["http"]["routers"]["home"]
        assert merged["services"]["home"] == {}
        for section, entries in additions["http"].items():
            for name, value in entries.items():
                assert merged[section][name] == value
        if domain:
            assert merged["routers"]["fluxer"]["entryPoints"] == [entrypoint]
            assert ("tls" in merged["routers"]["fluxer"]) == (entrypoint == "websecure")
    for invalid in [
        '{"http": {"routers": {"home": {}}}}',
        '{"http": {"services": {"home": {}}}}',
        '{"http": {"routers": {"fluxer": {}}}}',
        '{"tcp": {}}', '{"http": null}', '{"http": {"routers": []}}',
        '{"http": {"routers": {"broken": null}}}',
        'http:\n  routers: {}\n  routers: {}\n',
    ]:
        custom.write_text(invalid)
        result = render("fluxer.example.com")
        assert result.returncode != 0 and not result.stdout and result.stderr, invalid
print("Custom route merging, existing routes, TLS and invalid/conflicting configuration passed.")
PY
