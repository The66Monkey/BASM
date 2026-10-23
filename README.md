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
- update.sh: pull latest images and refresh the stack
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

The wizard offers standard ports (HTTP 80 / HTTPS 443), a local test range,
or advanced custom ports after module selection. Selected ports are saved and
propagate to Compose mappings, module configs, and summary URLs. See
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
`/opt/basm-local`. It does not complete the existing upstream ERPNext/Postal
provisioning or turn placeholder modules into working applications.
See [local installation details](docs/installation.md#local-and-lan-testing)
for LAN hostname mappings, module behavior, and maintenance commands.

## Security note

Use strong admin passwords, keep SSH access locked down, and point DNS and router forwarding at your public IP before bringing services live.

## License

- Software: MIT License — [LICENSE](LICENSE)
- Documentation: CC BY 4.0 — [LICENSE-docs](LICENSE-docs)
- Attribution guidance: [ATTRIBUTION.md](ATTRIBUTION.md)

BASM is free to use, adapt, and self-host. If BASM helps your organization or project, a mention of the BASM Framework by ScandinavianHacking is appreciated.
