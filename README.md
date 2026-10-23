# BASM

BASM (Business, Accounting, Storage, Mail) is a reference architecture and deployment framework for small businesses. It is designed to run on a single Debian server and provide a simple, modular, self-hosted stack for business operations that usually need a basic ERP, mail, file sync, backups, and secure network access.

## What BASM is

BASM is an opinionated deployment framework that composes open-source services, uses upstream Docker images, and keeps the operations simple enough for small teams and consultants.

## Goals

- Use only open-source software
- Prefer upstream first
- Keep services modular and understandable
- Make deployments repeatable on a fresh Debian host
- Keep operational overhead low for 1-10 users
- Avoid vendor lock-in

## Included stack

- ERPNext for core business operations
- Postal for self-hosted mail handling
- Nextcloud for file sync and collaboration
- Restic for backups
- Traefik for TLS and reverse proxying
- Optional LAMP, WireGuard, Fluxer, Vaultwarden, and Uptime Kuma services

## Repository layout

- install.sh: main installer and configuration wizard
- uninstall.sh: remove BASM services and data
- update.sh: pull latest images and refresh the core and module stacks
- config/: environment values and generated defaults
- modules/: modular installers for optional components
- templates/: Docker and proxy configuration templates
- docs/: operations documentation
- output/: generated deployment summary and logs

## Quick start

1. Clone or copy this project to a fresh Debian server.
2. Run: sudo ./install.sh
3. Complete the setup wizard.
4. Confirm the selected modules.
5. Review the generated summary under output/installation-summary.txt.

The wizard offers standard ports (HTTP 80 / HTTPS 443 / SMTP 25), a local test
range, or advanced custom ports after module selection. Selected ports are saved
and propagated to Compose mappings, module configs, and summary URLs. See
[port setup](docs/installation.md#port-setup) for the complete port table.

## Local and LAN testing

Run `sudo ./install.sh`. When asked for your primary domain, enter your domain
(for example, `example.com`) or enter `local` to choose the local test setup.
Accept the default `localhost` bind address for loopback-only access. The wizard
uses HTTP on port 18080 by default for local testing, without public DNS or Let's Encrypt.
Open http://localhost:18080 or http://127.0.0.1:18080 for Nextcloud;
ERP and mail routes use http://erp.localhost:18080 and http://mail.localhost:18080.

To allow LAN clients, enter the server's private IPv4 address (for example,
`192.168.1.50`) at the local bind-address question instead of accepting localhost.
Wildcard and public bindings are rejected. Do not forward these ports on a router.

Local mode keeps separate configuration, container names, and data under
`/opt/basm-local`. It initializes ERPNext, Nextcloud, and Postal's web interface
with generated credentials, and runs encrypted daily Restic backups. Credentials
are stored in `/opt/basm-local/config/basm.env` with root-only permissions. Local
Postal SMTP binds only to loopback; it is not an internet mail server. See
[local installation details](docs/installation.md#local-and-lan-testing)
for service access, LAN hostname mappings, and mail limitations.

## Upgrading and promoting

- Basic to full: `sudo ./install.sh --full` adds LAMP, WireGuard, and Uptime Kuma
  to an existing install without touching core services, data, or credentials.
  The basic install saves ports for the full profile and stages Compose YAML
  and WireGuard server/client configs under
  `<BASM_ROOT>/config/prepared-modules/`. These services stay inactive until
  selected; upgrading reuses the settings and generated WireGuard keys.
- Local to production: `sudo ./install.sh --promote` removes the local test
  stack and its data and creates a fresh production install. It carries over
  organization settings and the module selection.

Neither path upgrades system packages or re-downloads cached Docker images. See
[upgrading](docs/installation.md#upgrading-from-basic-to-full) and
[promoting](docs/installation.md#promoting-a-local-test-install-to-production).

## Security note

Use strong admin passwords, keep SSH access locked down, and point DNS and router forwarding at your public IP before bringing services live.

## License

- Software: MIT License — [LICENSE](LICENSE)
- Documentation: CC BY 4.0 — [LICENSE-docs](LICENSE-docs)
- Attribution guidance: [ATTRIBUTION.md](ATTRIBUTION.md)

BASM is free to use, adapt, and self-host. If BASM helps your organization or project, a mention of the BASM Framework by ScandinavianHacking is appreciated.

## Implementation Details

The core profile is provisioned as a complete Compose stack rather than a set of
placeholder containers. ERPNext uses the official Frappe service topology
(MariaDB, Redis, configurator, one-shot site creation, backend, frontend,
websocket, scheduler, and worker). Site creation is safe to rerun, and the
scheduler is explicitly enabled. Nextcloud is preconfigured with MariaDB, Redis,
and a generated administrator account, so its browser setup wizard is not needed.

Postal follows its current v3 deployment model: MariaDB, a one-shot schema
initializer, web, SMTP, and worker services. It does not use RabbitMQ. Its web
port is private to the Compose network and proxied by Traefik. The Postal web
process binds to the container network interface so the proxy can reach it;
local SMTP is published only on `127.0.0.1:2525`. Production SMTP uses TCP 25,
but real mail delivery still depends on public DNS and provider network policy.

On first install, generated service credentials and deployment values are stored
outside the repository at `<BASM_ROOT>/config/basm.env` with mode `0600`; the
summary lists account names but does not print passwords. Postal's mounted config
and signing key are readable by Postal's non-root container account and are not
world-readable. The wizard also asks for the Nextcloud admin name and backup
destination, validates hostnames and time zones, and warns when production DNS,
host sizing, or SMTP port prerequisites are not met.

The backup path is executable, : MariaDB databases are
dumped daily, then Restic encrypts application data, configuration, and dumps.
Retention is seven daily, four weekly, and twelve monthly snapshots. The default
repository is local to the host, so an off-host copy is still required for
disaster recovery.

The installer and maintenance scripts are executable directly from the checkout.
Optional LAMP, Uptime Kuma, and WireGuard modules remain opt-in and make up the
full profile; LAMP and Uptime Kuma start automatically when selected. Fluxer and
Vaultwarden are placeholders and are not included in either profile.
