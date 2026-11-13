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

### Stalwart

Provides inbound/outbound SMTP, user mailboxes, IMAP, authenticated SMTP
submission, and mail administration. It stores messages, accounts, and settings
in its persistent local data store; it does not require another MariaDB.

- IMAP over TLS and authenticated SMTP submission are published on TCP 993 and
  465. The first-run setup listener is loopback-only.
- TCP 443 is routed by Traefik as TLS passthrough for `mx.<domain>`, allowing
  Stalwart to serve its WebUI and manage its own mail-protocol certificates.
- SMTP port 25 is published for inbound internet mail in production and bound
  to loopback in local mode. ERPNext can send through authenticated Stalwart SMTP.
- Stalwart's mailbox data and configuration are included in coordinated
  backups; no SQL dump is needed for its embedded database.

## Configuration and secrets

- Deployment values and generated credentials are stored outside the
  repository at `<BASM_ROOT>/config/basm.env` with mode `0600`.
- Settings are parsed as data, not sourced as shell code. Traefik routes are
  structurally merged into one mapping, including optional Fluxer routes.
- Selected ports are saved and propagated to Compose mappings, module configs,
  and summary URLs.
- Generated secrets are reused to recreate containers and deployment artifacts
  when BASM is upgraded or modules are reconfigured. Legacy Postal settings may
  be read from an older environment file for upgrade compatibility but are not
  used or re-saved.
- The summary lists account names but never prints passwords.
- The wizard validates hostnames and time zones, and warns when production DNS,
  host sizing, or SMTP port prerequisites are not met.
- Local mode uses separate configuration, container names, and data under
  `/opt/basm-local`.
- Basic installs stage Compose YAML and WireGuard configs under
  `<BASM_ROOT>/config/prepared-modules/` for later `--full` upgrades.

## Backups

The host runs one coordinated 02:00 backup. Writers pause before fresh MariaDB
dumps; databases and module stacks then stop for a cold, complete snapshot.
Previously running services restart on success or failure. Restic covers the
deployment root, including installed code, all module data, saved image digests
and a Fluxer recovery archive, while excluding logs and the backup destination.
Retention is seven daily, four weekly and twelve monthly snapshots.

## Automatic updates

- The updater is installed under `<BASM_ROOT>/maintenance/` with a
  deployment-specific job in `/etc/cron.d/`.
- Schedule: 03:00 on January 1 and July 1 (cron month field `1,7`).
- Manual and scheduled updates use the same complete pre-update backup.
- Compatible image channels resolve to digest locks. Nextcloud upgrades are
  sequential; database-series and ERPNext-major transitions require tested
  scripts under `migrations/`. Scripts receive `BASM_ROOT` and `BASM_ENV_FILE`.
- All operator mutations and installer actions share a lock. Interrupted updates
  retain `config/update-in-progress` and block retries. There is no automatic rollback.
- Scheduled updates refuse execution outside 00:00-06:00. They do not update
  Debian or fetch BASM source releases; reviewed source can be supplied manually.
- Logs: `<BASM_ROOT>/logs/automatic-updates.log`.
- Disable with `<BASM_ROOT>/config/disable-auto-updates`; this survives
  installer reruns. Cron schedule edits are reset by installer reruns.

## Operator tools

`bin/basm`, `update.sh`, `recover.sh`, module helpers, templates and `VERSION`
are installed under `maintenance/`; `/usr/local/bin/basm` points to the CLI.
`modules/operations.sh` handles locking, scheduling, health and notifications;
`modules/backup.sh` handles snapshots/restores; `modules/releases.sh` handles
release gates and application updates. `modules/core.sh` retains installation
and business handover logic.

Hourly checks validate expected services, web endpoints, backup age and free
space. Failures reach the journal and an optional configured HTTPS webhook.
See [testing](testing.md) for automated coverage and remaining live acceptance.

## Dynamic DNS

For dynamic-IP installs, `/etc/cron.d/basm-ddns-*` runs every four hours and
updates deSEC A records for the primary, ERP, mail, cloud and `mx` hostnames
(plus Fluxer when selected) when the public IPv4 changes. The updater tries two
public IPv4 lookup services. The token lives in
`<BASM_ROOT>/config/basm.env`; changes and lookup failures are logged to
`<BASM_ROOT>/logs/ddns.log`.

## Modules

The full production profile includes Core, LAMP, HotDog CMS, Uptime Kuma,
WireGuard, Fluxer, KeePassXC, and RustDesk Server OSS. Each optional module can
also be selected individually. LAMP, Uptime Kuma, and RustDesk start
automatically when selected.
HotDog CMS automatically selects LAMP and serves its published site from a
separate Apache virtual host.
Fluxer requires production HTTPS and is managed by `rexctl` behind BASM Traefik, with direct voice
media ports and BASM-integrated backups. Vaultwarden is deprecated for new
installs; KeePassXC is the supported credential-manager module. The installer
and maintenance scripts are executable directly from the checkout.
