# BASM Installation Guide

This document explains how to install BASM on a fresh Debian server and bring the stack online with minimal operational overhead.

## Requirements

- Fresh Debian 12 or compatible Debian-based host
- Root access or sudo privileges
- Public static IP or routed network access
- Domain names for ERP, mail, and cloud subdomains
- A router that allows port forwarding for HTTP and HTTPS traffic

## Steps

1. Copy the BASM project to the Debian host.
2. Review the defaults in config/defaults.env.
3. Run the installer as root or with sudo.
4. Complete the configuration wizard.
5. Select the desired modules.
6. Review the generated summary in output/installation-summary.txt.

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

`custom` prompts for HTTP, HTTPS, SMTP, and all full-profile modules' ports,
even on a basic install, so future services have a reusable port plan. Values must
be between 1 and 65535. Duplicate TCP mappings, including collisions with the
recorded host SSH port and future full-profile services, are rejected by the
wizard. Existing host listeners produce warnings;
stop the current owner or choose custom ports before starting a conflicting
service. SSH is not changed by any profile. WireGuard's port is written to its
generated configuration; the module does not start a VPN server.

Values are saved to the environment configuration and used when generating
Compose mappings, module configuration, and summary URLs. Adding a module later
reuses its saved port and checks it against the existing plan. If it conflicts,
rerun the full wizard with that module selected and choose custom ports.

Only Traefik publishes the shared web entry points. Postal, ERPNext, and
Nextcloud are reached by hostname over the private Compose network, so their
internal listening ports do not compete for host port 80. Do not start separate
upstream web proxies publishing the same host port alongside BASM's Traefik.
Fluxer remains a placeholder in this repository; there is no Fluxer server or
port mapping to configure yet.

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
192.168.1.50 erp.basm.test mail.basm.test cloud.basm.test
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

Optional modules: LAMP and Uptime Kuma are started automatically when selected
(each as its own Compose project named `<prefix>-lamp` / `<prefix>-uptime-kuma`).
LAMP serves `<BASM_ROOT>/modules/lamp/www`, seeded with a placeholder page.
WireGuard generates a server config and a `peer1.conf` client config with fresh
keys (mode `0600`, kept on reruns) but does not start a VPN server. Fluxer and
Vaultwarden are placeholders.
LAMP uses port 18081 in local mode and Uptime Kuma uses 18301 with the local port
profile, both bound to the selected local address. `uninstall.sh` stops them and
`update.sh` updates them together with the core stack. The wizard rejects
conflicting port assignments among the selected services.

### Local maintenance

```bash
sudo ./install.sh --module lamp
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

## Upgrading from basic to full

A basic install runs BASM Core only (ERPNext, Nextcloud, Postal, Traefik, and
Restic backups). The full profile adds LAMP, WireGuard, and Uptime Kuma:

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
- The summary lists the inactive module ports and configuration locations.

Prepared directories are separate from active modules, so maintenance commands
do not start or update them. On selection, the installer moves each prepared
directory into `<BASM_ROOT>/modules/`, refreshes its ports/bindings from the saved
environment, and preserves its contents and WireGuard keys. The saved environment,
not the human-readable summary or log, is authoritative. WireGuard's generated
server and peer endpoint ports stay synchronized on reruns; it still requires
manual server setup. Treat prepared WireGuard files as secrets and include the
deployment configuration in backups.

Enter the domain of the install to upgrade, or `local` for the local test setup.
The upgrade:

- Leaves the running core stack, credentials, and data untouched.
- Does not run `apt-get` and does not re-pull core images.
- Reuses the saved module ports. If they conflict with the current port plan,
  it prompts for new module ports only.
- Records the new module list in `<BASM_ROOT>/config/basm.env`, starts LAMP and
  Uptime Kuma, and refreshes the summary.

It is safe to rerun. `sudo ./install.sh --module <name>` adds a single module in
the same way. In the full wizard, enter `full` at the module menu; a blank
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
