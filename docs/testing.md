# Testing

Run `bash tests/run.sh` with Bash, ShellCheck, jq, gettext, OpenSSL, Restic,
Python 3 with PyYAML/pykeepass, and Docker Compose v2. No root or Docker daemon
is needed. `COMPOSE_BIN` and `RESTIC_BIN` can select standalone validators.

Tests cover:

- Generated Traefik routes, duplicate keys, service references and Compose shape.
- Local/private binding, saved credentials, module upgrades and handovers.
- Data-only configuration parsing and invalid settings.
- Complete encrypted snapshots and verified staged restores with real Restic.
- Optional-module files, backup exclusions, stopped services and restart failures.
- Backup, pull and health failure gates; interrupted-update retry protection.
- Nextcloud/database version policy, operation locks, freshness/disk thresholds,
  and optional webhook payloads.

## Live acceptance still required

Passing isolated tests is not a production deployment claim. On a disposable
Debian host with non-sensitive data, validate:

- Fresh installation and adoption from the previous release, all selected modules.
- Real ERPNext migrations, Nextcloud upgrades, Postal mail delivery and Fluxer calls.
- Nightly stop/backup/restart timing, external webhook delivery and six-month scheduling.
- Full replacement-host recovery with saved accounts, files, databases and RustDesk keys.
- Reboot behavior, missing backup mounts, TLS/DNS and public/private reachability.

DEN is unchanged by these improvements and keeps its home-user workflow.
