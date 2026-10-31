# BASM

BASM (Business, Accounting, Storage, Mail) is an opinionated deployment framework for small businesses that runs on a single Debian server and combines established open-source services into a complete business platform running on local infrastructure.

<p align="center">
  <img src="docs/images/mascot.png" alt="BASM mascot" width="300">
</p>


## What gets installed?

- ERPNext for core business operations
- Postal for self-hosted mail handling
- Nextcloud for file sync and collaboration
- Restic for encrypted backups
- Traefik for TLS and reverse proxying
- Optional Fluxer chat, LAMP, WireGuard, Uptime Kuma, and KeePassXC credential manager modules.

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

Encrypted daily Restic snapshots cover application data, configuration, and
database dumps (7 daily, 4 weekly, 12 monthly). The default repository is on the
server itself, so copy it to a separate system. See [backup](docs/backup.md).

## How are updates handled?

Application images are updated automatically on January 1 and July 1 after a
database dump and Restic snapshot; a failed backup stops the update. Run
`sudo ./update.sh` for a manual update. See
[operations](docs/operations.md#automatic-application-updates).

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
