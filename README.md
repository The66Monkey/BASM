# BASM

BASM (Business, Accounting, Storage, Mail) is an opinionated deployment framework for small businesses that runs on a single Debian server and combines established open-source services into a complete business platform running on local infrastructure.

<p align="center">
  <img src="docs/images/mascot.png" alt="BASM mascot" width="300">
</p>


## What gets installed?

- ERPNext for core business operations
- Postal for self-hosted mail handling
- Nextcloud for file sync and collaboration
- Fluxer for self-hosted community chat and voice/video
- Restic for encrypted backups
- Traefik for TLS and reverse proxying
- Optional LAMP, WireGuard, Uptime Kuma, RustDesk Server OSS, and KeePassXC credential manager modules. The full profile includes every supported module, including Fluxer; Vaultwarden is deprecated for new installs.

Everything runs as Docker Compose stacks on a single Debian server.

## Quick start

A production install needs a **static public IPv4 address** and a DNS domain
(for example from [deSEC](https://desec.io)). Without a static IP, choose
`non-static` in the wizard; see [operations](docs/operations.md#dynamic-ip-non-static-installs).

**Minimum system requirements:**
- Debian 12 or 13
- 30GB disk space (for Docker images and application data)
- 2GB RAM minimum (4GB+ recommended)
- Root access or sudo privileges

1. Clone or copy this project to a fresh Debian server.
2. Run: `sudo ./install.sh`
3. Complete the setup wizard and confirm the selected modules.
4. Review `output/installation-summary.txt`.
5. Deliver the **For the User** document (mode 0600) to the owner and **For IT** 
   to the IT administrator (see [operations](docs/operations.md#owner-and-it-handover)).

To try BASM without DNS or a router, enter `local` as the domain. See
[local and LAN testing](docs/installation.md#local-and-lan-testing).

To uninstall BASM completely, run: `sudo ./uninstall.sh`

To add a self-hosted RustDesk ID and relay server, select option `8` in the
wizard or run `sudo ./install.sh --module rustdesk` on an existing install.
See [RustDesk setup](docs/installation.md#rustdesk-server-oss) for client settings,
ports, and key backups. RustDesk is also included in the production `--full` profile.

## Where is configuration stored?

Outside the repository, under `<BASM_ROOT>/config/` (`/opt/basm` for production,
`/opt/basm-local` for local mode). The main file is `config/basm.env`.

## How are credentials handled?

Credentials are generated at install time and stored in root-only files. They are
never printed in the summary or logs; the owner receives them in the private
**For the User** handover document. See the [security model](docs/security-model.md).

With the optional KeePass module, credentials are stored in an encrypted KDBX
database instead; the user document contains only its location and master password.

## How are backups handled?

At 02:00, applications briefly pause for encrypted Restic snapshots covering
all modules, configuration, database dumps and recovery image versions
(7 daily, 4 weekly, 12 monthly). Keep an independent off-host copy.
See [backup and recovery](docs/backup.md).

## How are updates handled?

Application images are updated automatically at **03:00 on January 1 and July 1**
(server time). Both automatic and manual updates require a complete backup,
record immutable image versions, and gate incompatible major upgrades.
Run `sudo basm update` for a manual update. See
[operations](docs/operations.md#automatic-application-updates).

## Day-to-day operation

Use `sudo basm status`, `sudo basm check`, and `sudo basm logs`.
For a local install, add `--root /opt/basm-local` before the command.
Hourly checks detect missing services, stale backups and low disk space.
An optional HTTPS webhook can notify IT of failures; see
[operations](docs/operations.md#checks-and-failure-notifications).

## What survives upgrades?

Credentials, service settings, ports, update schedules, and module selections are
kept across installer reruns and upgrades. `./install.sh --full` adds modules
without touching core services or data. See
[upgrading](docs/installation.md#upgrading-from-basic-to-full).

## Documentation

- [Installation](docs/installation.md)
- [Reinstalling & Upgrading](docs/reinstalling.md)
- [Operations](docs/operations.md)
- [Architecture](docs/architecture.md)
- [Service layout](docs/service-layout.md)
- [Security model](docs/security-model.md)
- [Router setup](docs/router-setup.md)
- [Backup](docs/backup.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

- Software: MIT License — [LICENSE](LICENSE)
- Documentation: CC BY 4.0 — [LICENSE-docs](LICENSE-docs)
- Attribution guidance: [ATTRIBUTION.md](ATTRIBUTION.md)

BASM is free to use, adapt, and self-host. If BASM helps your organization or project, a mention of the BASM Framework by [ScandinavianHacking](https://scandinavianhacking.se/) is appreciated.
