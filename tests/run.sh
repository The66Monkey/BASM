#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
for script in install.sh update.sh recover.sh uninstall.sh bin/basm modules/*.sh templates/*.sh templates/profile.d/*.sh tests/*.sh; do
  bash -n "$script"
done
shellcheck --severity=error -x -P "$ROOT" install.sh update.sh recover.sh uninstall.sh bin/basm modules/*.sh templates/*.sh templates/profile.d/*.sh tests/*.sh
bash tests/configuration.sh
bash tests/homepage.sh
bash tests/backup-destination.sh
bash tests/backup-storage.sh
bash tests/local-mode.sh
bash tests/lifecycle.sh
bash tests/keepass.sh
bash tests/operations.sh
bash bin/basm help >/dev/null
bash update.sh --help >/dev/null
printf 'All BASM automated checks passed. No live services were deployed.\n'
