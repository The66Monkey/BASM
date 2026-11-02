# Operations Guide

Day-to-day procedures for a running BASM server. Use `/opt/basm-local` in place
of `/opt/basm` for local installs; a custom `BASM_ROOT` uses its own tree.

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

```sh
sudo less /opt/basm/handover/for-the-user.txt
sudo less /opt/basm/handover/for-it.txt
```

The `handover/` directory has mode `0700` and both documents mode `0600`.
Re-running the installer or upgrading modules regenerates them from the saved
configuration. Passwords changed inside applications must be recorded
separately; BASM cannot retrieve them.

## Dynamic IP (non-static installs)

Answer `N` or `non-static` at the public IP question and provide a deSEC API token.
BASM installs `/etc/cron.d/basm-ddns-*`, which checks the public IPv4 every
4 hours and updates the deSEC A records for the primary, ERP, mail, cloud and
`mx` hostnames, plus the Fluxer hostname when selected, when it changes.
External access can be down for up to about 4 hours
after a change. All hostnames must belong to the same deSEC domain. Changes are
logged to `<BASM_ROOT>/logs/ddns.log`. Expect possible mail deliverability
problems on a dynamic IP.

## Migrating a hand-built server

`recover.sh` accepts complete BASM-format backups, not an arbitrary Mint/Docker
installation. For a legacy installation, first save native application backups,
configuration, encryption/signing keys, image versions and a database-consistent
RustDesk SQLite backup. Keep a second verified copy before importing into a
fresh BASM installation. Never copy a running database's raw files or restore
another MariaDB version's system tables over the replacement.

Restore ERPNext's database and public/private files, preserve its encryption
key, and run migrations for the target application version. Restore Postal's
application databases and signing/Rails secrets, retaining BASM's database
connection settings. Preserving RustDesk's server keys avoids changing the
identity configured on its clients. Imported application logins may differ
from the fresh-install handover; update the private handover accordingly.

Leave background mail delivery and ERP scheduling paused until cutover to avoid
duplicate processing. Verify data counts, logins, file access and application
workflows, not just container startup. Export DNS before editing it. Keep the
source available for rollback until DNS, forwarding, certificates, VPN, backups
and external clients have all been tested.

### Home-lab migration checkpoint (2026-11-02)

This deployment-specific checkpoint is not a supported installer profile:

- Fedora DEN host: `192.168.50.245`, with KVM/libvirt and Cockpit Machines.
  Its wired `enp3s0` is a port of `br0`; the host address is on the bridge.
- Debian 13 BASM VM: `192.168.50.20`, MAC `52:54:00:cd:c7:7f`, 2 vCPUs,
  6 GiB RAM and a 40 GiB disk; configured to autostart. Reserve its DHCP address.
- Selected modules: core, LAMP, Uptime Kuma, KeePassXC and RustDesk. BASM Fluxer
  and BASM's standard WireGuard module are not selected.
- Mint source: `192.168.50.52` (also `.50`), still available; ERPNext, Postal
  and RustDesk were imported. Selected ERP data counts, Postal account/domain
  counts and the RustDesk public-key checksum match the source.
- ERPNext worker/scheduler and Postal SMTP/worker remain stopped pending
  cutover. The imported ERP site's scheduler is also disabled.
- Compatibility stacks are under `/opt/basm/modules/migrated-network` and
  `/opt/basm/modules/migrated-heartbeat`. These are manually managed additions,
  not new built-in BASM modules.
- Migrated AdGuard exposes DNS TCP/UDP 53 and administration TCP 3000 on the
  VM's LAN IP. WireGuard retains its keys/subnet (`10.13.13.0/24`) and UDP 51820;
  its CoreDNS now forwards to AdGuard. Local DNS queries pass; remote-client VPN
  handshakes and LAN access still need testing. Do not publicly forward 53/3000.
- Heartbeat retains unauthenticated `POST /heartbeat` on TCP 8000 with
  `{"hostname":"kiosk-01","public_ip":"198.51.100.42"}` and response
  `{"status":"ok"}`. Hostname/IP validation prevents path traversal; writes are
  atomic. Existing JSON files were retained. No API key is required for legacy
  clients: submissions can be spoofed, so treat them only as IP-discovery hints
  and retain SSH host-key verification. An actual kiosk update is not yet verified.
- Heartbeat uses a locally imported image ID, not a registry-published image.
  Recovery requires saving/loading that image separately; a Compose file alone
  cannot pull it on a fresh machine.
- Router changes to BASM were reported applied. All three public hostnames
  passed ACME staging validation using a separate resolver/storage file, then
  production issuance. Trusted HTTPS now returns ERP 200 and Postal/Cloud 302;
  authenticated workflows and external-client tests are not yet signed off. DEN public
  Fluxer HTTPS is temporarily unavailable under the BASM-first forwarding plan.
- The guest OS still reports `Etc/UTC`. The wizard's application timezone does
  not set the OS timezone; verify it separately because maintenance uses the
  server clock.

Source migration bundles are under `/backup/basm-migration-20261102.*` on Mint,
with a verified copy under `/var/backups/mint-migration-20261102` in the VM.
These contain secrets and must stay access-restricted. They are outside
`/opt/basm`, so BASM's normal deployment snapshot does not include them.
Restic snapshots before and after the main application import passed full
verification; the heartbeat stack was added afterwards and needs a new backup.
The repository is still on the VM's system disk, not independent backup storage.
Full replacement-host `recover.sh` validation remains pending.

Existing legacy VPN profiles retain their server identity because keys, peer
addresses and UDP 51820 were preserved. New QR codes are not required solely
for this move. Check the endpoint, DNS and a real handshake after forwarding
changes. DEN's separate VPN profiles use UDP 41873 and are not interchangeable
with the migrated legacy VPN. Never publish profiles or QR codes in documentation.

To operate a compatibility stack explicitly:

```sh
sudo docker compose -f /opt/basm/modules/migrated-network/docker-compose.yml ps
sudo docker compose -f /opt/basm/modules/migrated-heartbeat/docker-compose.yml ps
```

Before retiring Mint: finish public TLS, resume and test held services, verify
real clients, take a fresh backup plus an independent copy and test recovery.
Retain source disks without wiping them. Remove the temporary
`/etc/sudoers.d/99-copilot-session` grant on both original hosts when maintenance
access is no longer needed.

## Automatic application updates

The updater runs as root at **03:00 on January 1 and July 1** using the server's
clock. Missed runs are not caught up, and updates can briefly interrupt
services. Scheduled execution is restricted to 00:00-06:00; it will not replay a
missed run during business hours. Manual updates are explicitly operator-triggered.
If the nightly backup still holds the lock, scheduled updates wait up to two
hours and recheck the maintenance window before starting.

Both manual and scheduled updates resolve compatible image channels, take a
complete consistent backup, and apply digest-locked images. Nextcloud cannot
skip major releases or downgrade. Database-series changes require a tested
release migration, as do ERPNext major changes. ERPNext runs its site migration
before dependent applications start. A failed/interrupted application step leaves
`config/update-in-progress` and blocks retries; there is no automatic rollback.

Nextcloud 33, ERPNext 16, Traefik 3 and the configured MariaDB/Redis series can
receive compatible channel updates. Exact-version pins, including Postal, need
reviewed BASM releases to advance. Neither Debian packages nor BASM source are
automatically upgraded. Six-month updates do not replace urgent security fixes.

Fluxer uses its own `rexctl upgrade` with upstream migration/backup handling;
the complete BASM backup includes a Fluxer archive before any update.

Logs: `<BASM_ROOT>/logs/automatic-updates.log`. Daily complete backups run at
02:00 and log to `logs/backup.log`; the old independent backup-container loops
and separate Fluxer cron job are replaced.

Disable automatic runs (survives installer reruns); remove the file to re-enable:

```sh
sudo touch /opt/basm/config/disable-auto-updates
```

For quarterly runs, change the cron month field from `1,7` to `1,4,7,10` in
this deployment's file under `/etc/cron.d/`; installer reruns restore the
six-month schedule.

For an immediate manual update, run `sudo basm update`. To apply a reviewed BASM
checkout, use `sudo basm update --release /path/to/checkout`. Never use an
untrusted checkout: release code and migrations run as root. The checkout needs
a numeric `VERSION`; downgrades are rejected. All mutating operator commands and
installer actions share the deployment lock.

## Checks and failure notifications

```sh
sudo basm status
sudo basm check
sudo basm logs nextcloud
```

Use `--root /opt/basm-local` before the command for local mode. Hourly checks
validate expected containers (including successful initializers), web endpoints,
Fluxer when selected, backup age (under 36 hours), and filesystem usage (under
90%). Checks defer explicitly during maintenance. WireGuard configuration is
checked when selected, but BASM does not claim that a manually enabled host VPN
is healthy.

Failures are recorded in the system journal and `logs/last-failure`. For optional
external notifications, place one HTTPS endpoint URL in
`config/alert-webhook` with mode `0600`. The receiver gets JSON containing
`host`, `deployment`, and `message`; no credentials or command output are sent.
Test with `sudo basm alert-test`. Delivery failures are logged and do not hide
the original failure. No webhook is contacted unless configured.

## Private management services

Production LAMP and Uptime Kuma bind to loopback by default, not the public
wildcard address. Access them with SSH tunnels, or save a private LAN IPv4 as
`MANAGEMENT_BIND_ADDRESS` in `config/basm.env` and rerun their module installers.
Local-mode modules follow the selected private bind address. Existing modules
keep their binding until regenerated; review them during adoption. BASM does
not replace an administrator's firewall/router policy.

## Upgrading and promoting

- `sudo ./install.sh --full` adds every supported module (LAMP, WireGuard,
  Uptime Kuma, Fluxer, KeePassXC, and RustDesk) to an existing production install
  without recreating core services, data, or credentials. Local mode requires
  individual module selection or promotion first because Fluxer needs HTTPS.
- `sudo ./install.sh --module fluxer` adds the optional Fluxer chat stack behind
  BASM Traefik, including its persistent data, database dumps, and update path.
- `sudo ./install.sh --promote` replaces a local test install with a fresh
  production install, carrying over organization settings and module selection.

These paths install missing module prerequisites but do not upgrade installed
system packages; cached Docker images are reused. See
[installation.md](./installation.md#upgrading-from-basic-to-full) and
[promoting](./installation.md#promoting-a-local-test-install-to-production).
