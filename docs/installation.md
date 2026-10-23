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
- Generates environment values in config/basm.env
- Deploys the selected modules
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
| LAMP HTTP (TCP) | 8080 | 18081 |
| Uptime Kuma HTTP (TCP) | 3001 | 18301 |
| WireGuard ListenPort (UDP) | 51820 | 18520 |

`custom` prompts for HTTP, HTTPS, and the selected modules' ports. Values must
be between 1 and 65535. Duplicate TCP mappings, including collisions with the
recorded host SSH port, are rejected. Existing host listeners produce warnings;
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
change. Production HTTPS URLs include the selected port. Let's Encrypt TLS
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
- Local configuration is generated separately as `config/local.env`.
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

### Current service limitations

Local mode configures networking for the existing reference stack. The current
ERPNext and Postal templates still require their upstream databases, initialization,
and application provisioning before those routes serve working applications.
Mail delivery is not configured for internet use. Complete Nextcloud's initial
setup in the browser; its trusted domains include the local names and bind address.
The existing Restic container is a placeholder, not a configured backup service.

Optional modules retain their existing behavior: LAMP and Uptime Kuma generate
Compose files but do not start automatically; WireGuard generates a configuration;
Fluxer and Vaultwarden are placeholders. LAMP uses port 18081 in local mode and
Uptime Kuma uses 18301 with the local port profile, both bound to the selected local address. To start generated
optional services explicitly:

```bash
sudo docker compose -f /opt/basm-local/modules/lamp/docker-compose.yml up -d
sudo docker compose -f /opt/basm-local/modules/uptime-kuma/docker-compose.yml up -d
```

Stop these optional services with the same commands replacing `up -d` with `down`
before removing local data. The wizard rejects conflicting port assignments
among the selected services.

### Local maintenance

```bash
sudo ./install.sh --module lamp
sudo ./update.sh
sudo ./uninstall.sh
```

Each command asks for a domain or local test setup; enter `local` to select this
environment. Uninstall prompts before deleting local
data. Production configuration remains in `config/basm.env` and is not overwritten.
To use a custom data directory, pass `BASM_ROOT` consistently to all commands,
for example `sudo env BASM_ROOT=/opt/basm-lab ./install.sh`, then choose `local`.

Run the isolated networking regression test without root or Docker:

```bash
bash tests/local-mode.sh
```

It requires Bash and `envsubst` (Debian package `gettext-base`) and writes only
to a temporary directory, which is removed on exit.

## Upstream project references

The BASM stack intentionally uses upstream projects and their official install guidance:

- Postal: https://docs.postalserver.io/getting-started/installation
- Postal repo: https://github.com/postalserver
- ERPNext upstream: https://github.com/frappe/erpnext
- ERPNext Docker repo: https://github.com/frappe/frappe_docker

## Common maintenance

- Use update.sh to pull new images and recreate services
- Use uninstall.sh to remove the stack and generated volumes
- Keep backups in a dedicated storage location outside the live service path

## Suggested defaults

- ERP URL: erp.domain.tld
- Mail URL: mail.domain.tld
- Cloud URL: cloud.domain.tld
- Backup directory: /var/backups/basm

## Recovery note

BASM is intentionally modular. If one service fails, it can be repaired or replaced without restarting the entire stack.
