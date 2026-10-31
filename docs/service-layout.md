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
| `<BASM_ROOT>/maintenance/` | Protected automatic updater |
| `<BASM_ROOT>/logs/` | `automatic-updates.log`, `ddns.log` |
| `<BASM_ROOT>/modules/` | Active optional modules, including Fluxer’s Compose bundle and root-only `.env` |
| `<BASM_ROOT>/data/fluxer/` | Fluxer service volumes and PostgreSQL dumps |
| `<BASM_ROOT>/data/db-backups` | Database dumps (`0700`/`0600`) |
| `<BASM_ROOT>/backups/restic` | Default local Restic repository (local mode) |
| `/etc/cron.d/` | Deployment-specific update and DDNS jobs |

## Compose projects and naming

- Core stack: ERPNext, Nextcloud, Postal, Traefik, and Restic backup job.
- Optional modules run as separate Compose projects named `<prefix>-lamp`,
  `<prefix>-uptime-kuma`, and `<prefix>-fluxer`.
- Fluxer’s Caddy edge joins BASM’s private Docker network; BASM Traefik provides
  its public hostname and TLS. Voice media uses separately published TCP/UDP ports.
- Local mode prefixes container names with `basm-local-` to avoid collisions.

## Hostnames

| Mode | ERP | Mail | Cloud |
| --- | --- | --- | --- |
| Production | `erp.<domain>` | `mail.<domain>` | `cloud.<domain>` |
| Local (loopback) | `erp.localhost` | `mail.localhost` | `cloud.localhost` |
| Local (LAN) | `erp.basm.test` | `mail.basm.test` | `cloud.basm.test` |

## Ports

Only Traefik publishes the shared web ports. Application ports stay on the
private Compose network. See the port table in
[installation.md](./installation.md#port-setup). Postal SMTP is published on TCP 25
in production and `127.0.0.1:2525` in local mode.

## Repository templates

`templates/` holds the Compose, Traefik, Postal, systemd, and DDNS templates
rendered at install time. `modules/*.sh` contain the module installers and
`install.sh`, `update.sh`, and `uninstall.sh` are the entry points.
