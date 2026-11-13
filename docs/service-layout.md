# Service Layout

Reference for where things live on a BASM host. `<BASM_ROOT>` is `/opt/basm`
for production and `/opt/basm-local` for local mode.

## Directory tree

| Path | Contents |
| --- | --- |
| `<BASM_ROOT>/config/basm.env` | Authoritative saved settings and credentials (`0600`) |
| `<BASM_ROOT>/config/prepared-modules/` | Staged, inactive module configs for `--full` |
| `<BASM_ROOT>/config/disable-auto-updates` | Marker that disables scheduled updates |
| `<BASM_ROOT>/handover/` | For-the-User and For-IT documents (`0700`) |
| `<BASM_ROOT>/maintenance/` | Installed operator CLI, updater, recovery code and templates |
| `<BASM_ROOT>/logs/` | Update, backup, health and DDNS logs; `last-failure` |
| `<BASM_ROOT>/home/` | Generated public start page and mascot; no credentials |
| `<BASM_ROOT>/config/images.json` | Saved core image digests |
| `<BASM_ROOT>/config/update-in-progress` | Interrupted-update gate |
| `<BASM_ROOT>/config/backup-device` | Saved backup filesystem identity; rejects missing or changed mounts |
| `<BASM_ROOT>/config/backup-device.before-adopt.*` | Previous identities retained by verified mount adoption |
| `<BASM_ROOT>/config/alert-webhook` | Optional private HTTPS notification endpoint |
| `<BASM_ROOT>/modules/` | Active optional modules (LAMP, HotDog CMS, Uptime Kuma, WireGuard, Fluxer) |
| `<BASM_ROOT>/modules/fluxer/` | Fluxer `rexctl` settings and managed Compose project |
| `<BASM_ROOT>/modules/hotdog/site/` | HotDog CMS source site and publish target configuration |
| `<BASM_ROOT>/modules/lamp/hotdog/current/` | Published HotDog static site, served separately from LAMP's `www/` |
| `<BACKUP_LOCATION>/fluxer/` | Upstream Fluxer archives |
| `<BASM_ROOT>/data/fluxer-recovery.tar.zst` | Latest Fluxer archive copied into the complete snapshot |
| `<BASM_ROOT>/data/stalwart/` | Stalwart mailboxes and embedded database |
| `<BASM_ROOT>/data/db-backups` | Database dumps (`0700`/`0600`) |
| `<BASM_ROOT>/backups/restic` | Default local Restic repository (local mode) |
| `/etc/cron.d/` | Deployment-specific update, backup, check and DDNS jobs |

## Compose projects and naming

- Core stack: ERPNext, Nextcloud, Stalwart and Traefik. Restic runs on the host.
- A static homepage container serves the main production domain through Traefik;
  it publishes no host port and mounts only the generated page read-only.
- Optional modules run as separate Compose projects named `<prefix>-lamp`,
  `<prefix>-uptime-kuma`, and `<prefix>-fluxer` (the Fluxer project is managed
  by its upstream `rexctl` CLI).
- HotDog CMS runs its CLI on the host and publishes static files into the LAMP
  project; Apache serves them from a separate virtual host.
- Fluxer serves through BASM Traefik; voice media uses separately published
  TCP/UDP ports.
- Local mode prefixes container names with `basm-local-` to avoid collisions.

## Hostnames

| Mode | ERP | Mail and administration | Cloud | HotDog website |
| --- | --- | --- | --- | --- |
| Production | `erp.<domain>` | `mx.<domain>` | `cloud.<domain>` | `hotdog.<domain>` |
| Local (loopback) | `erp.localhost` | `mx.localhost` | `cloud.localhost` | `hotdog.localhost` |
| Local (LAN) | `erp.basm.test` | `mx.basm.test` | `cloud.basm.test` | `hotdog.basm.test` |

The optional `mail.<domain>` alias redirects to the canonical `mx.<domain>`
hostname.
When HotDog CMS is selected, its production hostname is `hotdog.<domain>`.

## Ports

Only Traefik publishes the shared web ports. Application ports stay on the
private Compose network. See the port table in
[installation.md](./installation.md#port-setup). Stalwart SMTP is published on
TCP 25 in production and `127.0.0.1:2525` in local mode. Stalwart publishes SMTP
submission on TCP 465 and IMAP over TLS on TCP 993 in production; its first-run
setup listener is loopback-only.

## Repository templates

`templates/` holds the Compose, Traefik, systemd, and DDNS templates
rendered at install time. `modules/*.sh` contain the module installers and
`install.sh`, `update.sh`, `recover.sh`, `uninstall.sh`, and `bin/basm` are the entry points.
