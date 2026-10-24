# BASM

BASM (Business, Accounting, Storage, Mail) is an opinionated deployment framework for small businesses that runs on a single Debian server and combines established open-source services into a complete business platform running on local infrastructure.

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

A production install needs a **static public IPv4 address** from your ISP and a
DNS domain (for example from [deSEC](https://desec.io)). The domain, mail server,
and Let's Encrypt certificates all depend on DNS records that point to that IP;
if the IP changes and the records are not updated, the services become
unreachable and mail delivery fails. Mail servers also need a stable IP for
reverse DNS (PTR) and sender reputation, so ask your ISP for a static IP whenever
possible.

If you cannot get a static IP, answer `non-static` when the wizard asks for the
public IP type and enter a deSEC API token. BASM then installs a cron job
(`/etc/cron.d/basm-ddns-*`) that checks the public IPv4 every 4 hours and,
when it changes, updates the deSEC A records for the primary domain and the
ERP, mail, and cloud hostnames. Most home IPs change rarely, so this light
schedule is enough; after a change, external access can be down for up to
about 4 hours until the next check. The token is stored only in the root-only
`<BASM_ROOT>/config/basm.env`, and changes are logged to
`<BASM_ROOT>/logs/ddns.log`. The domain must be managed by deSEC, and all
hostnames must belong to the same deSEC domain. Expect possible mail
deliverability problems on a dynamic IP.

1. Clone or copy this project to a fresh Debian server.
2. Run: sudo ./install.sh
3. Complete the setup wizard, choosing `static` or `non-static` public IP.
4. Confirm the selected modules.
5. Review the generated summary under output/installation-summary.txt.
6. Securely hand the owner the generated **For the User** document and give
  their IT helper **For IT**, as described below.

The wizard offers standard ports (HTTP 80 / HTTPS 443 / SMTP 25), a local test
range, or advanced custom ports after module selection. Selected ports are saved
and propagated to Compose mappings, module configs, and summary URLs. See
[port setup](docs/installation.md#port-setup) for the complete port table.

## Owner and IT handover

Every completed install generates two plain-text documents with the actual
addresses, selected ports, and initial credentials for that deployment:

- **For the User**: service addresses, usernames and initial passwords, backup
  recovery details, and a separate technical credentials section. It identifies
  accounts that need manual setup and includes space for the IT contact.
- **For IT**: a numbered checklist covering router login, reserving the server's
  network address, DNS, exact TCP/UDP forwarding rules, mail setup, service
  checks, backups, and secure handover. Local testing has separate instructions
  that explicitly prohibit router forwarding.

The installer prints their location. On a standard production installation,
the installer or IT helper can open them on the server with:

```sh
sudo less /opt/basm/handover/for-the-user.txt
sudo less /opt/basm/handover/for-it.txt
```

For local testing, use `/opt/basm-local` instead of `/opt/basm`. A custom
`BASM_ROOT` uses its own `handover/` directory. The directory has mode `0700`
and both documents have mode `0600`: only root can read them by default.
Passwords are never printed in the installation summary or installer log.

The generated handover documents contain service addresses, credentials, and backup information.
Re-running the installer or upgrading modules regenerates the documents from the saved BASM configuration.
Passwords changed within applications must be recorded separately, as BASM cannot retrieve them.

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
are listed in the private **For the User** handover; BASM also keeps its settings
in `/opt/basm-local/config/basm.env` with root-only permissions. Local
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

## Automatic application updates

Completed installs and module upgrades install a protected updater under
`<BASM_ROOT>/maintenance/` and a deployment-specific job under `/etc/cron.d/`.
It runs as root at **03:00 on January 1 and July 1**, using the server's clock
and time zone, without requiring the original checkout or user interaction.
Cron must be running, and the server must be on at the scheduled time; missed
runs are not caught up automatically. Updates can briefly interrupt services.

Before changing applications, the scheduled updater dumps all three databases
and creates an encrypted Restic snapshot. If either fails, it stops without
updating applications. It prevents overlapping updater runs, pulls configured
Docker image tags, recreates core and selected module containers, and waits
for running/healthy services. Failures stop the run and are logged; there is
no automatic rollback or external failure notification.

Logs are stored in `<BASM_ROOT>/logs/automatic-updates.log`. IT should check
them after scheduled runs and still maintain tested off-site backups.
This updates images within their configured tags, not Debian packages, the
BASM checkout, or version-pinned applications to newer releases. Pinned
versions still need periodic IT review and any upstream migration steps.
Six-month updates are not a substitute for urgent security fixes.

For manual-only operation, create the following file on the server (use
`/opt/basm-local` for local installs). This choice survives installer reruns:

```sh
sudo touch /opt/basm/config/disable-auto-updates
```

Remove that file to re-enable automatic runs. For quarterly runs, IT can change
the month field from `1,7` to `1,4,7,10` in this deployment's cron file; installer
reruns restore the six-month schedule. Run `sudo ./update.sh` from the checkout
for an immediate manual update after confirming a usable backup. Manual runs
use the same overlap lock but do not create the scheduled pre-update snapshot.

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
owner receives readable login details in the private **For the User** handover.
The summary lists account names but does not print passwords. Postal's mounted config
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
