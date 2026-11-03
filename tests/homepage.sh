#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/modules/core.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
BASM_ROOT="$TEMP/live"
COMPANY_NAME='Business <script>alert("bad")</script> & {{SERVICES}}'
ERP_URL=erp.example.com CLOUD_URL=cloud.example.com MAIL_URL=mail.example.com
FLUXER_DOMAIN=chat.example.com
RESTIC_PASSWORD=must-not-be-published
for mode in production local; do
  for modules in basm 'basm fluxer'; do
    for port in 443 19443; do
      DEPLOYMENT_MODE="$mode" BASM_MODULES="$modules" HTTPS_PORT="$port" HTTP_PORT=19080 render_homepage
      python3 - "$BASM_ROOT" "$COMPANY_NAME" "$mode" "$modules" "$port" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys

root, company, mode, modules, port = sys.argv[1:]
page = Path(root, "home/index.html").read_text()

class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.text = []
        self.scripts = 0

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.links.append(dict(attrs)["href"])
        if tag == "script":
            self.scripts += 1

    def handle_data(self, data):
        self.text.append(data)

parsed = Page()
parsed.feed(page)
scheme, suffix = ("https", "" if port == "443" else ":" + port) if mode == "production" else ("http", ":19080")
hosts = ["erp", "cloud", "mail"] + (["chat"] if "fluxer" in modules.split() else [])
assert parsed.links == [f"{scheme}://{host}.example.com{suffix}/" for host in hosts] + ["https://github.com/The66Monkey/BASM"]
assert company in "".join(parsed.text)
assert "Welcome to your BASM" in "".join(parsed.text)
assert not parsed.scripts
assert "must-not-be-published" not in page
assert "3001" not in page and "8080" not in page
assert Path(root, "home/mascot.png").is_file()
assert Path(root, "home").stat().st_mode & 0o777 == 0o755
assert Path(root, "home/index.html").stat().st_mode & 0o777 == 0o644
PY
    done
  done
done
(
  BASM_RENDER_DIR="$TEMP/staged" BASM_MODULES=basm HTTPS_PORT=443 render_homepage
  cmp "$ROOT_DIR/docs/images/mascot.png" "$TEMP/staged/home/mascot.png"
)
(
  ROOT_DIR="$TEMP/missing" BASM_MODULES=basm HTTPS_PORT=443
  mkdir -p "$ROOT_DIR"
  if render_homepage >"$TEMP/error.log" 2>&1; then
    printf 'Missing start-page assets unexpectedly succeeded.\n' >&2
    exit 1
  fi
)
printf 'Start-page links, optional modules, custom ports, escaping and missing assets passed.\n'
