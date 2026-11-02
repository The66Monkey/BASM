# BASM Installation Guide

This document explains how to install BASM on a fresh Debian server and bring the stack online with minimal operational overhead.

## Requirements

- Fresh Debian 12 or compatible Debian-based host
- Root access or sudo privileges
- Public static IP or routed network access
- Domain names for ERP, mail, and cloud subdomains
- A router that allows port forwarding for HTTP and HTTPS traffic

During Debian's software selection, enable **SSH server** for remote
administration. Leave **web server** unselected: BASM provides Traefik and
uses ports 80 and 443 by default, which can conflict with a host web server.

## Steps

1. Copy the BASM project to the Debian host.
2. Review the defaults in config/defaults.env.
3. Run the installer as root or with sudo.
4. Complete the configuration wizard.
5. Select the desired modules.
6. Review the generated summary in output/installation-summary.txt.

For prompts showing a value in square brackets, press Enter to accept that
default, or type a replacement and press Enter. For example, at
`ERP URL [erp.example.com] (press Enter to accept):`, pressing Enter keeps
`erp.example.com`. Prompts without a default require an answer.

For **Public IP type**, enter `S` for static or `N` for non-static (dynamic IP).
Letters are case-insensitive; `static` and `non-static` also work. Press Enter
to accept the displayed default. Non-static mode asks for a deSEC API token and
enables automatic DNS updates.

### Choosing a timezone

Enter an IANA timezone name, such as `Europe/Stockholm` for anywhere in Sweden
(including Varberg), rather than a city name like `Varberg` or an abbreviation
like `CET`. Regional timezones automatically handle daylight-saving changes.
Press Enter to keep the displayed default; `Etc/UTC` uses UTC all year.

Run `timedatectl list-timezones` in another terminal to browse available names.

### Choosing a backup destination

The wizard offers a numbered list: the default directory, writable mounted disk
filesystems, and a custom directory. Disk choices use a `basm-backups`
subdirectory on the selected mount. The installer does not format or mount disks;
attach and mount a backup disk or network share before starting the wizard.
Unmounted disks and host disks not attached/shared with a VM are not available.

Press Enter to keep the default (`/var/backups/basm` in production). This normally
stores backups on the system disk; the wizard warns if the destination shares
the system filesystem. It is useful for initial testing but does not protect
against disk failure. A different partition or virtual disk on the same physical
disk also does not provide disk-failure protection. Keep an independent encrypted
off-host copy; see [backup and recovery](backup.md).

## Installer behavior

The installer does the following:

- Detects Debian and verifies root access
- Installs Docker and the Docker Compose plugin
- Installs common requirements and base tooling
- Creates the BASM directory structure
- Generates deployment config and strong service credentials under the BASM data root
- Initializes the ERPNext site, Nextcloud account, and Postal database/admin user
- Schedules encrypted daily database and file backups with Restic
- Deploys the selected optional modules
- Creates the post-installation summary
- Installs the `basm` operator command, hourly checks and optional webhook support
- Adds a compact interactive login banner with the host name, IPv4 address, and
  BASM container status

Production LAMP and Uptime Kuma bind to loopback by default. Use SSH tunnels or
set `MANAGEMENT_BIND_ADDRESS` to a private LAN IPv4 before regenerating those
modules. Their unencrypted administration ports must not be forwarded publicly.

## Port setup

After module selection, the wizard asks for a port profile. Enter `standard`,
`local`, or `custom`. Domain deployments default to standard ports; local test
deployments default to the local range. The port profile does not change the
chosen bind address, domain, or HTTP/TLS mode.

| Service | Standard | Local Test |
| --- | --- | --- |
| Traefik HTTP (TCP) | 80 | 18080 |
| Traefik HTTPS (TCP) | 443 | 18443 |
| Postal SMTP (TCP) | 25 | 2525 (loopback only) |
| LAMP HTTP (TCP) | 8080 | 18081 |
| Uptime Kuma HTTP (TCP) | 3001 | 18301 |
| WireGuard ListenPort (UDP) | 51820 | 18520 |
| RustDesk NAT test (TCP) | 21115 | 22115 |
| RustDesk ID (TCP/UDP) | 21116 | 22116 |
| RustDesk relay (TCP) | 21117 | 22117 |
| Fluxer voice (TCP) | 7881 | 17881 |
| Fluxer voice (UDP) | 7882 | 17882 |

`custom` prompts for HTTP, HTTPS, SMTP, all full-profile modules' ports, and
selected Fluxer voice ports, so services have a reusable port plan. Values must
be between 1 and 65535. Duplicate TCP mappings, including collisions with the
recorded host SSH port and future full-profile services, are rejected by the
wizard. Existing host listeners produce warnings;
stop the current owner or choose custom ports before starting a conflicting
service. SSH is not changed by any profile. WireGuard's port is written to its
generated configuration; the module does not start a VPN server. Fluxer's voice
ports are published only on the selected bind address.

Values are saved to the environment configuration and used when generating
Compose mappings, module configuration, and summary URLs. Adding a module later
reuses its saved port and checks it against the existing plan. If it conflicts,
rerun the full wizard with that module selected and choose custom ports.

Only Traefik publishes the shared web entry points. Postal, ERPNext, and
Nextcloud are reached by hostname over the private Compose network, so their
internal listening ports do not compete for host port 80. Do not start separate
upstream web proxies publishing the same host port alongside BASM's Traefik.
Fluxer is available as an opt-in production module. BASM installs it with the
official `rexctl` manager behind Traefik at `chat.<domain>`; create that DNS A
record and forward the configured Fluxer voice TCP and UDP media ports. Its web
edge does not claim BASM's TCP 80/443 ports. The first admin account is created
interactively during installation. Fluxer is not supported in BASM local mode,
and is included in the production `--full` profile.

Traefik's static listeners remain on container ports 80/443; only host mappings
change. In production, HTTP requests are permanently redirected to HTTPS. Production HTTPS URLs include the selected port. Let's Encrypt TLS
validation still requires public TCP port 443 to reach Traefik, even when the
chosen host HTTPS port differs. Arrange appropriate routing for production.

## Local and LAN testing

On a Debian test host, run:

```bash
sudo ./install.sh
```

At the primary-domain question, enter your domain (such as `example.com`) for
a normal deployment, or enter `local` for a local test setup. `localhost` and
`127.0.0.1` also select local testing. Accept the default `localhost` at the
local bind-address question to keep access loopback-only. No mode flags are needed.

This still installs system packages and Docker and requires root. Package and
image downloads require internet access. Local mode does not create a VM or
isolate the host operating system; use a disposable Debian VM when appropriate.
It does not change SSH settings, open firewall rules, or configure your router.

- Published container ports bind to `127.0.0.1`, not all interfaces.
- HTTP defaults to port 18080. Local routes do not use TLS or request certificates.
- Cloud: http://localhost:18080, http://127.0.0.1:18080, or http://cloud.localhost:18080.
- ERP route: http://erp.localhost:18080.
- Mail route: http://mail.localhost:18080.
- Local configuration and generated passwords are stored under `/opt/basm-local/config/` with mode `0600`.
- Postal SMTP listens on `127.0.0.1:2525`; local mode cannot deliver internet mail.
- Restic encrypts daily backups in `/opt/basm-local/backups/restic`.
- Data and backups default to `/opt/basm-local` and `/opt/basm-local/backups`.
- Container names use the `basm-local-` prefix to avoid production collisions.
- The generated summary is `output/local-installation-summary.txt`.

Choose `custom` in the port setup question to change ports. If your resolver does not support
`.localhost` subdomains, add `127.0.0.1 erp.localhost mail.localhost cloud.localhost`
to the test machine's hosts file. On systems where `localhost` resolves to IPv6
first, use `127.0.0.1`; this mode binds IPv4 only.

For LAN access, choose `local` and enter a private IPv4 address assigned to the
server, such as `192.168.1.50`, at the local bind-address question.

Only loopback and RFC 1918 addresses are accepted; `0.0.0.0` and public addresses
are rejected. LAN mode uses `erp.basm.test`, `mail.basm.test`, and
`cloud.basm.test`, because `.localhost` names are reserved for loopback.
Add this entry to each client's hosts file, or configure equivalent private DNS:

```text
192.168.1.50 erp.basm.test mail.basm.test cloud.basm.test chat.basm.test (when Fluxer is selected)
```

Open http://192.168.1.50:18080 for Cloud, http://erp.basm.test:18080 for ERP,
or http://mail.basm.test:18080 for mail. Adjust the address and port to match your
configuration. Do not configure public DNS or router port forwarding. HTTP is
unencrypted, so use test credentials and only trusted networks. Binding to a
private address is not a firewall or a guarantee against upstream NAT forwarding.

### Service readiness

ERPNext and Nextcloud are initialized with generated administrator credentials.
The Postal web UI and database are initialized, but local mode cannot validate real
mail delivery. Production mail requires working public DNS, correct MX/SPF/DKIM/DMARC
records, a stable IP address, and a provider that permits inbound and outbound TCP
port 25. Postal's upstream guidance recommends a dedicated host with at least 4 GB
RAM and 2 CPU cores.

Restic initializes an encrypted local repository and takes daily snapshots of
application files, configuration, and database dumps. A local repository is not
an off-host backup; configure an external copy and test restores.

Optional modules: Fluxer, RustDesk, LAMP, and Uptime Kuma are started automatically when selected
(each as its own Compose project named `<prefix>-lamp` / `<prefix>-uptime-kuma`).
LAMP serves `<BASM_ROOT>/modules/lamp/www`, seeded with a placeholder page.
WireGuard generates a server config and a `peer1.conf` client config with fresh
keys (mode `0600`, kept on reruns) but does not start a VPN server. Fluxer and
Fluxer is not available in local mode because it requires production HTTPS and
public voice networking. Vaultwarden is deprecated and cannot be selected for
new installs; use KeePassXC.
LAMP uses port 18081 in local mode and Uptime Kuma uses 18301 with the local port
profile, both bound to the selected local address. `uninstall.sh` stops them and
`update.sh` updates them together with the core stack. The wizard rejects
conflicting port assignments among the selected services.

## RustDesk Server OSS

Select option `8` in the wizard, or add it to an existing deployment:

```bash
sudo ./install.sh --module rustdesk
```

BASM runs the official `rustdesk/rustdesk-server:1.1.16` image as two services,
`hbbs` (ID/rendezvous) and `hbbr` (relay), in the `<prefix>-rustdesk` Compose
project. RustDesk can be selected individually and is included in `--full`. This is the open-source
server, not Pro: no web console, API server, or administrator account is created.

Production clients use the primary domain's existing DNS A record. Forward
TCP 21115, TCP/UDP 21116, and TCP 21117 to the same server ports, or the selected
custom ports listed in the handover. Do not use a CDN HTTP proxy for this DNS
record. RustDesk traffic does not pass through Traefik. Configure host filtering
as well; Docker-published ports can bypass UFW. WebSocket ports 21118/21119 are
not published, and web clients are not configured.

In each RustDesk desktop client's Network settings, enter:

- **ID server:** `<primary-domain>:21116`
- **Relay server:** `<primary-domain>:21117`
- **Key:** contents of `<BASM_ROOT>/modules/rustdesk/data/id_ed25519.pub`
- **API server:** leave blank

Both services require the server key (`-k _`). This is not a substitute for
device-level connection approval or a strong unattended-access password.
The public key is generated at first startup; retrieve it on the server with:

```bash
sudo cat /opt/basm/modules/rustdesk/data/id_ed25519.pub
```

Use the actual deployment root if different. Never distribute `id_ed25519`, the
private key. Test registration and force a relay connection between two devices
before handing over the service.

Local mode binds only to the selected loopback/private IPv4. Use that IP in
clients with ID port 22116 and relay port 22117 by default; do not forward router
ports. Custom values are saved as `RUSTDESK_NAT_PORT`, `RUSTDESK_ID_PORT`, and
`RUSTDESK_RELAY_PORT`. The NAT port must be exactly one below the ID port.

Keys and the SQLite database persist in `<BASM_ROOT>/modules/rustdesk/data` and
survive reruns and container recreation. The existing updater pulls the pinned
image tag; moving to a new server release requires changing the image version
in the module and regenerating its configuration. Uninstall deletes this data.
Local-to-production promotion also creates a new identity; update client keys.

BASM's complete nightly Restic backup includes the RustDesk data directory and
stops both services for a consistent SQLite copy. Keep an independent off-host
repository copy. Restore the saved identity before starting the services.

### Local maintenance

```bash
sudo ./install.sh --module lamp
sudo ./install.sh --module fluxer
sudo ./install.sh --full
sudo ./update.sh
sudo ./uninstall.sh
```

Each command asks for a domain or local test setup; enter `local` to select this
environment. Uninstall prompts before deleting local
data. Production configuration remains in `config/basm.env` and is not overwritten.
To use a custom data directory, pass `BASM_ROOT` consistently to all commands,
for example `sudo env BASM_ROOT=/opt/basm-lab ./install.sh`, then choose `local`.

Run the isolated regression tests without root or Docker:

```bash
bash tests/local-mode.sh
bash tests/lifecycle.sh
```

It requires Bash and `envsubst` (Debian package `gettext-base`) and writes only
to a temporary directory, which is removed on exit.

## Production prerequisites

- The administrator email is used as the Let's Encrypt account contact. Production
  rejects reserved addresses such as `admin@example.com` or `*.test`, because Let's
  Encrypt refuses them and no certificates would be issued.
- MariaDB first-start initialization can take more than a minute per database;
  health checks allow up to five minutes before failing the install.
- Database dumps under `<BASM_ROOT>/data/db-backups` are root-only (`0700`/`0600`).

## Optional KeePass credential manager

Select option `7` in the module menu, alongside any other desired modules, or
add it to an existing deployment:

```bash
sudo ./install.sh --module keepass
```

Enter `local` for a local test deployment with KeePass selected individually.
KeePass is also included automatically in the production `full` profile.

This installs KeePassXC and the Debian `python3-pykeepass` library. BASM creates
`<BASM_ROOT>/vaults/admin/credentials.kdbx`, a standard encrypted KeePass database, and
stores its generated master password in
`<BASM_ROOT>/config/keepass-master-password`. Both files have mode `0600`.
KeePassXC is a desktop application, not a browser interface or network service.
On a headless server, open a securely delivered database copy with a
KeePass-compatible application on the owner's computer.
For a canonical server file rather than independent editable downloads, see
[private shared-vault access](keepass-sharing.md).

When selected, the **For the User** document contains the database location and
one master password instead of individual service credentials. The summary and
**For IT** guide refer to the database without including its master password.
The database contains BASM-generated administrator and database passwords, the
Restic password, Postal signing material, any deSEC API token, and generated
WireGuard files, including prepared configurations.

BASM cannot discover passwords for accounts created manually, such as Uptime
Kuma, the server, or the router. IT must fill in the provided entries for these
accounts. Application-managed credentials not known to BASM remain in their
application data and backups.

Rerunning the installer adds missing entries without overwriting existing
entries or changing the master password. Update KeePass entries when changing
passwords in applications. If changing the database master password, also update
the protected saved master-password file before rerunning the installer.
Close KeePassXC before installer or handover regeneration. Synchronization
refuses a present KeePassXC lock file or a detected concurrent file change;
this is not distributed locking across all clients.
Older `config/credentials.kdbx` files are migrated into `vaults/admin/`, retaining
a protected `config/credentials.kdbx.pre-share` rollback copy. If both locations
already contain a database, synchronization stops for administrator review.
An existing rollback copy is never overwritten; reconcile it manually before
retrying a migration.
Keep an independent recovery copy of the database and master password: a Restic
backup alone cannot recover the password needed to decrypt itself.

Machine-readable service settings remain in the protected environment file;
this option removes individual credentials from the human handover documents,
not from the runtime configuration required by the services.

Run the dedicated integration tests after installing `python3-pykeepass`:

```bash
bash tests/keepass.sh
```

## Upgrading from basic to full

A basic install runs BASM Core only (ERPNext, Nextcloud, Postal, Traefik, and
Restic backups). The full profile includes every supported module: Core, LAMP,
WireGuard, Uptime Kuma, Fluxer, KeePassXC, and RustDesk Server OSS. Vaultwarden
is deprecated and unavailable for new installs; backup and Traefik are already
included in Core. Full requires production mode because Fluxer needs HTTPS:

```bash
sudo ./install.sh --full
```

The basic install prepares the upgrade without starting optional services:

- `<BASM_ROOT>/config/basm.env` is the root-only, machine-readable source used
  by the installer for all ports, bindings, domains, credentials, and module selection.
- `<BASM_ROOT>/config/prepared-modules/lamp/` and
  `<BASM_ROOT>/config/prepared-modules/uptime-kuma/` contain ready-to-use Compose
  YAML. The LAMP directory also contains its initial web page.
- `<BASM_ROOT>/config/prepared-modules/wireguard/` contains `config.conf` and
  `peer1.conf` with generated keys and the selected endpoint/UDP port, mode `0600`.
- `<BASM_ROOT>/config/prepared-modules/rustdesk/` contains the ID/relay Compose
  configuration. Keys are created only when the selected service starts.
- Fluxer and KeePass are installed only when selected, not during preparation.
- The summary lists the inactive module ports and configuration locations.

Prepared directories are separate from active modules, so maintenance commands
do not start or update them. On selection, the installer moves each prepared
directory into `<BASM_ROOT>/modules/`, refreshes its ports/bindings from the saved
environment, and preserves its contents and WireGuard keys. The saved environment,
not the human-readable summary or log, is authoritative. WireGuard's generated
server and peer endpoint ports stay synchronized on reruns; it still requires
manual server setup. Treat prepared WireGuard files as secrets and include the
deployment configuration in backups.

Enter the production domain of the install to upgrade. For a local install,
promote first or add local-compatible modules with `--module <name>`; local
`--full` is rejected without changing the deployment.
The upgrade:

- Leaves the running core stack, credentials, and data untouched.
- Installs missing module prerequisites (including KeePassXC and
  `python3-pykeepass`) without upgrading installed packages or re-pulling core images.
- Reuses the saved module ports. If they conflict with the current port plan,
  it prompts for new module ports only.
- Records the new module list in `<BASM_ROOT>/config/basm.env`, starts LAMP,
  Uptime Kuma, Fluxer, and RustDesk, creates the KeePass database, and refreshes
  the summary. Fluxer performs interactive administrator setup; WireGuard
  still requires manual server setup.

It is safe to rerun. `sudo ./install.sh --module <name>` adds a single module in
the same way. To add Fluxer, use `sudo ./install.sh --module fluxer` or select it
in the wizard. In the full wizard, enter `full` at the module menu; a blank
answer keeps the modules that are already installed.

## Promoting a local test install to production

When testing is complete, replace the local install with a production install:

```bash
sudo ./install.sh --promote
```

The command asks for the production domain and requires typing `promote` to
confirm. It then:

1. Asks the normal production questions (URLs, backup directory, ports),
   prefilled with the company name, admin email, time zone, Nextcloud admin
   name, and module selection from the local install.
2. Stops the local stacks (keeping their data) and creates a fresh production
   install under `/opt/basm` with new credentials, public bindings, standard
   ports, HTTPS, and Let's Encrypt.
3. Only after production starts successfully, removes the local containers,
   networks, volumes, and `/opt/basm-local` (including local backups stored
   inside it). Local backups stored elsewhere are kept.

If production setup fails, the partial production install is removed and the
local install is restarted unchanged, so you can fix the problem and rerun.

Test data is not migrated. Docker images are not removed, so production starts
from the images already cached locally; Compose only downloads images that are
missing. System packages are only installed if missing and are never upgraded.
Promotion refuses to run if a production stack already exists at `/opt/basm`.
Complete the DNS, router, and mail prerequisites listed in the production
summary before going live.

All installer runs install only missing system packages, including Docker
(`apt-get install --no-upgrade`), and skip `apt-get update` when nothing is
missing. Use `update.sh` when you intentionally want newer images.

## Upstream project references

The BASM stack intentionally uses upstream projects and their official install guidance:

- Postal: https://docs.postalserver.io/getting-started/installation
- Postal repo: https://github.com/postalserver
- ERPNext upstream: https://github.com/frappe/erpnext
- ERPNext Docker repo: https://github.com/frappe/frappe_docker

## Common maintenance

- Use update.sh to pull new images and recreate the core and module services
- Use uninstall.sh to remove the stack and generated volumes
- Keep backups in a dedicated storage location outside the live service path

## Suggested defaults

- ERP URL: erp.domain.tld
- Mail URL: mail.domain.tld
- Cloud URL: cloud.domain.tld
- Backup directory: /var/backups/basm

## Recovery note

BASM is intentionally modular. If one service fails, it can be repaired or replaced without restarting the entire stack.
