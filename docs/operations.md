# Operations Guide

Routine tasks for a running BASM server. Paths below assume `/opt/basm`; use
your configured root, or `/opt/basm-local` for local mode.

## Start page

Open `https://YOUR-DOMAIN/` (include your configured HTTPS port if nonstandard).
The public start page shows the business name and links to business services;
it grants no application access. Postal's link is for mail administration, not
an employee inbox. LAMP, Uptime Kuma, vaults and server access remain private and
are not linked. Sign in separately to each application.

Local tests use `http://home.localhost:18080/`, or `home.basm.test` with private
LAN DNS and the selected HTTP port. The existing localhost/IP Nextcloud routes
remain available. Pages are regenerated from saved settings during installation,
application updates and module route refreshes, and included in backups/recovery.
Do not add secrets to the generated `<BASM_ROOT>/home/` directory.

## Quick reference

| Task | Command or guide |
| --- | --- |
| Service status | `sudo basm status` |
| Health check | `sudo basm check` |
| Application logs | `sudo basm logs nextcloud` |
| Backup now | `sudo basm backup` |
| Verify backup contents | `sudo basm verify-backup` |
| Move VM backups onto host storage | [VM backup storage and verified mount adoption](virtual-machines.md) |
| Recovery | [Backup and recovery](backup.md) |
| Admin, team and personal password vaults | [KeePass sharing](keepass-sharing.md) |
| Import an old server or test a migration | [Migration and acceptance](migration.md) |
| DNS, certificates and forwarding | [Network setup](router-setup.md), [troubleshooting](troubleshooting.md) |

For local-mode commands, put `--root /opt/basm-local` before the command.

## Custom reverse-proxy routes

Optional administrator-owned `config/traefik-custom.yml` adds named HTTP
`routers`, `services`, `middlewares` and `serversTransports` to generated
Traefik configuration. Keep it private (`0600`). Managed names cannot be
overridden; invalid mappings and duplicate names fail rendering.
This file is retained across route refreshes, application updates and backups.
Do not edit generated `config/traefik.yml` for persistent changes.

Adding a public route is an explicit access-policy decision. Use exact hostname
rules, a certificate resolver in production, and verified TLS for remote HTTPS
backends (set `serversTransports.<name>.serverName` when connecting by IP).
Custom DNS records must be managed separately. Changes take effect at the next
route refresh or application update; merely saving the custom file does not
reload Traefik.

### BASM behind a separate HTTPS edge

BASM can remain a verified HTTPS application backend while a separate
infrastructure proxy owns public TCP 80/443. In that case TLS-ALPN certificate
renewal on BASM cannot reach its own challenge handler through a terminating
edge. Enable independent DNS-challenge renewal instead:
save a suitably scoped deSEC token privately in `data/traefik/desec-token`
(`0600`, root-owned). Route regeneration selects deSEC DNS-01 when this file
exists; the Traefik template reads it from the already-mounted data directory.
Recreate only Traefik after updating its environment/static configuration.
Without that file, standalone installations retain TLS-ALPN-01.
Do not delete the file without planning certificate renewal.

The outer edge must verify BASM's certificate and set SNI to the exact public
hostname when connecting to the VM's LAN IP. Keep BASM's ACME store separate
from the edge's store; do not share writable ACME files between proxies.
To preserve real client addresses, put only the edge's exact LAN IPv4 in the
private `config/traefik-edge-ip` file. Regeneration validates it and trusts
forwarded headers from that single address (`/32`), not the LAN or internet.
Without that file no forwarded-header sources are trusted. Recreate/restart
Traefik after changing its static configuration.
No root/business/mail DNS changes are required if the public IPv4 is unchanged.
Do not retire an old DNS service until legacy VPN DNS forwarders have been
pointed to the independent resolver.

## Owner and IT handover

Read these privately on the server:

```sh
sudo less /opt/basm/handover/for-the-user.txt
sudo less /opt/basm/handover/for-it.txt
```

- **For the User:** addresses, initial usernames/passwords (including Nextcloud),
  recovery details and technical credentials. Search for `Nextcloud` in the
  document to find its login.
- **For IT:** DNS, actual ports, router settings, mail setup and verification.

The directory is `0700`; documents are `0600`. Do not paste credentials into
chat, tickets or screenshots. Installer reruns/module upgrades regenerate the
handover. Application password changes and imported logins must be recorded
privately; BASM cannot retrieve passwords changed inside apps.

## Checks and failure notifications

Hourly checks cover expected containers and successful initializers, HTTPS
endpoints, selected Fluxer, backup age (under 36 hours), and disk usage (under
90%). Checks defer during maintenance. Selected WireGuard configuration is
checked, but that is not proof of a functioning VPN.

Failures appear in the system journal and `logs/last-failure`. To enable optional
notifications, save one HTTPS receiver URL in `config/alert-webhook` with mode
`0600`, then run `sudo basm alert-test`. Notifications contain only `host`,
`deployment` and `message`; delivery errors do not hide the original failure.
No receiver is contacted unless configured.

## Automatic application updates

| Job | Schedule (server OS timezone) | Log |
| --- | --- | --- |
| Consistent backup | Daily, 02:00 | `logs/backup.log` |
| Application update | January 1 and July 1, 03:00 | `logs/automatic-updates.log` |
| Health check | Hourly | Journal and `logs/last-failure` on failure |

Check `timedatectl` for the server timezone. The application's wizard timezone
does not change the OS clock.

**Run an update manually:**

```sh
sudo basm update
sudo basm update --release /path/to/trusted/checkout
```

Release code runs as root: use only a reviewed checkout with a numeric `VERSION`.
Downgrades are rejected. Mutating operations share a deployment lock.

**Disable automatic application updates** (survives installer reruns):

```sh
sudo touch /opt/basm/config/disable-auto-updates
```

Remove that file to re-enable. For quarterly updates, change the cron month
field from `1,7` to `1,4,7,10` under `/etc/cron.d/`; installer reruns restore
the six-month schedule.

### Update safeguards

- Missed updates are not replayed. Scheduled runs stay within 00:00–06:00.
  If a backup holds the lock, updates wait up to two hours and recheck the window.
- A complete backup precedes digest-locked application changes. ERPNext runs
  migrations before dependent services start.
- Nextcloud cannot skip major versions or downgrade. ERPNext major upgrades
  and database-series changes need a tested release migration.
- Nextcloud 33, ERPNext 16, Traefik 3 and configured MariaDB/Redis series receive
  compatible channel updates. Exact pins such as Postal need reviewed releases.
  Fluxer uses `rexctl upgrade` with its archive included in BASM backups.
- Debian packages and BASM source are not automatically upgraded. Six-month
  application updates do not replace urgent security fixes.
- Failed application updates leave `config/update-in-progress` and block retries.
  There is no automatic rollback: inspect logs and follow
  [recovery guidance](backup.md); do not remove the marker merely to retry.

## Dynamic IP (non-static installs)

Select `N` or `non-static` and supply a deSEC token. The DDNS cron job checks every
four hours, updating A records for the root, ERP, mail, cloud, `mx`, and selected
Fluxer when the public IPv4 changes. All names must belong to the same deSEC
domain. Logs: `logs/ddns.log`.

Access may be unavailable for up to roughly four hours after an address change.
Dynamic IPs can also harm mail deliverability. See [DNS setup](router-setup.md)
for records DDNS does not manage.

## Private management services

LAMP and Uptime Kuma bind to loopback in production. From your workstation:

```sh
ssh -N -L 18080:127.0.0.1:8080 -L 13001:127.0.0.1:3001 USER@BASM-LAN-IP
```

Open `http://localhost:18080` for LAMP or `http://localhost:13001` for Kuma.
Use configured ports if you changed the defaults. Do not publicly forward
these administration listeners.

Alternatively, save a private LAN IPv4 as `MANAGEMENT_BIND_ADDRESS` in
`config/basm.env` and rerun the relevant module installers. Existing bindings
are unchanged until regenerated. Local-mode modules use the selected private
bind address. BASM does not replace your firewall/router policy.

## Upgrading and promoting

| Installer option | Effect |
| --- | --- |
| `--module fluxer` | Add Fluxer behind BASM Traefik, including data, backups and updates |
| `--full` | Add all supported modules without recreating core data or credentials |
| `--promote` | Replace a local test deployment with a fresh production installation, retaining organization settings and module selection |

Full includes LAMP, WireGuard, Uptime Kuma, Fluxer, KeePassXC and RustDesk.
Local mode requires individual selection or promotion because Fluxer needs
production HTTPS. These paths install missing prerequisites but do not upgrade
installed packages; cached images are reused.

See [module upgrades](installation.md#upgrading-from-basic-to-full) and
[promotion](installation.md#promoting-a-local-test-install-to-production).
