# Architecture Notes

Technical reference for troubleshooting and for automated assistants working on
BASM. Operator-facing instructions are in the [README](../README.md).

## Overview

The core deployment uses Docker Compose and deploys complete upstream service
architectures rather than simplified all-in-one containers. Container images,
data volumes, database initialization, TLS routing, backups, and maintenance
jobs are managed by BASM and generated from templates in `templates/`.

## Services

### ERPNext

Follows the official Frappe topology: MariaDB, Redis, configurator, one-shot
site creation, backend, frontend, websocket, scheduler, and worker. Site
creation is safe to rerun, and the scheduler is explicitly enabled.

### Nextcloud

Preconfigured with MariaDB, Redis, and a generated administrator account, so
the browser setup wizard is not needed.

### Postal

Follows the current v3 deployment model: MariaDB, a one-shot schema
initializer, web, SMTP, and worker services. It does not use RabbitMQ.

- The web port is private to the Compose network and proxied by Traefik.
- The web process binds to the container network interface so the proxy can
  reach it.
- Local SMTP is published only on `127.0.0.1:2525`.
- Production SMTP uses TCP 25; real delivery depends on public DNS and
  provider network policy.
- The mounted config and signing key are readable by Postal's non-root
  container account and are not world-readable.

## Configuration and secrets

- Deployment values and generated credentials are stored outside the
  repository at `<BASM_ROOT>/config/basm.env` with mode `0600`.
- Selected ports are saved and propagated to Compose mappings, module configs,
  and summary URLs.
- Generated secrets are reused to recreate containers and deployment artifacts
  when BASM is upgraded or modules are reconfigured.
- The summary lists account names but never prints passwords.
- The wizard validates hostnames and time zones, and warns when production DNS,
  host sizing, or SMTP port prerequisites are not met.
- Local mode uses separate configuration, container names, and data under
  `/opt/basm-local`.
- Basic installs stage Compose YAML and WireGuard configs under
  `<BASM_ROOT>/config/prepared-modules/` for later `--full` upgrades.

## Backups

MariaDB databases are dumped daily, then Restic encrypts application data,
configuration, and dumps. Retention is seven daily, four weekly, and twelve
monthly snapshots. The default repository is local to the host, so an off-host
copy is required for disaster recovery.

## Automatic updates

- The updater is installed under `<BASM_ROOT>/maintenance/` with a
  deployment-specific job in `/etc/cron.d/`.
- Schedule: 03:00 on January 1 and July 1 (cron month field `1,7`).
- Before updating, it dumps all three databases and creates a Restic snapshot;
  failure of either aborts the run.
- It prevents overlapping runs (shared lock with `update.sh`), pulls configured
  image tags, recreates core and selected module containers, and waits for
  running/healthy state. There is no automatic rollback.
- Logs: `<BASM_ROOT>/logs/automatic-updates.log`.
- Disable with `<BASM_ROOT>/config/disable-auto-updates`; this survives
  installer reruns. Cron schedule edits are reset by installer reruns.

## Dynamic DNS

For `non-static` installs, `/etc/cron.d/basm-ddns-*` runs every 4 hours and
updates deSEC A records for the primary, ERP, mail, and cloud hostnames when
the public IPv4 changes. The token lives only in `<BASM_ROOT>/config/basm.env`;
changes are logged to `<BASM_ROOT>/logs/ddns.log`.

## Modules

LAMP, Uptime Kuma, and WireGuard are opt-in and make up the full profile; LAMP
and Uptime Kuma start automatically when selected. Fluxer and Vaultwarden are
placeholders and are not included in either profile. The installer and
maintenance scripts are executable directly from the checkout.
