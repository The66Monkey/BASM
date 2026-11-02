# Migration and Acceptance Guide

For routine commands, credentials and schedules, see [operations](operations.md).

- [Legacy import procedure](#migrating-a-hand-built-server)
- [Home-lab checkpoint](#home-lab-migration-checkpoint-2026-11-02)
- [Acceptance checklist](#post-migration-acceptance-tests)

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
- Mint source: `192.168.50.52` (also `.50`), powered down after cutover; ERPNext, Postal
  and RustDesk were imported. Selected ERP data counts, Postal account/domain
  counts and the RustDesk public-key checksum match the source.
- Mint's ERPNext, Postal and RustDesk services were stopped before their BASM
  replacements were enabled. BASM's ERPNext worker/scheduler and Postal
  SMTP/worker are running; the imported ERP site's scheduler is enabled.
  ERP background jobs completed, and `sudo basm check` passes after backup
  stop/restart. The earlier failed-health marker has cleared.
  Successful one-shot configurator/initialization containers may remain exited
  with code 0; they are not long-running services.
- Compatibility stacks are under `/opt/basm/modules/migrated-network` and
  `/opt/basm/modules/migrated-heartbeat`. These are manually managed additions,
  not new built-in BASM modules.
- Migrated AdGuard exposes DNS TCP/UDP 53 and administration TCP 3000 on the
  VM's LAN IP. WireGuard retains its keys/subnet (`10.13.13.0/24`) and UDP 51820;
  its CoreDNS now forwards to AdGuard. Local DNS queries pass; the owner confirmed
  the old VPN profile works from outside the home network, and two peers have
  recorded handshakes. The owner also confirmed an actual RustDesk connection.
  Do not publicly forward 53/3000.
- Heartbeat retains unauthenticated `POST /heartbeat` on TCP 8000 with
  `{"hostname":"kiosk-01","public_ip":"198.51.100.42"}` and response
  `{"status":"ok"}`. Hostname/IP validation prevents path traversal; writes are
  atomic. Existing JSON files were retained. No API key is required for legacy
  clients: submissions can be spoofed, so treat them only as IP-discovery hints
  and retain SSH host-key verification. A manual POST from the real kiosk returned
  OK and updated its server-side file at 22:33:46 UTC on 2026-11-02. This verifies
  the public path, not its recurring heartbeat schedule.
  The kiosk is outside without VPN and uses the public hostname on TCP 8000,
  not `192.168.50.20`;
  a successful RustDesk session does not provide VPN routing for its heartbeat.
- The restaurant kiosk is third-party-owned and explicitly untrusted; the owner
  only manages menu uploads. Assume it can be compromised at any time. Store no
  BASM/DEN credentials, vaults, administrator private keys or home VPN profiles
  there, and do not enroll it as a trusted LAN/VPN client. The unauthenticated
  HTTP heartbeat contains no authentication secret and grants no trusted identity.
  Treat its hostname/IP as attacker-controlled hints, not authority to execute
  commands or automatically accept a changed SSH host key. Keep management
  credentials on the trusted administrator device; do not forward an SSH agent
  to the kiosk. Minimize remote access to the menu-management task.
- Heartbeat uses a locally imported image ID, not a registry-published image.
  Recovery requires saving/loading that image separately; a Compose file alone
  cannot pull it on a fresh machine.
- Router changes to BASM were reported applied. All three public hostnames
  passed ACME staging validation using a separate resolver/storage file, then
  production issuance. Trusted HTTPS now returns ERP 200 and Postal/Cloud 302;
  the owner confirmed ERP settings and old Postal logs are retained after login.
  Nextcloud authenticated HTTPS WebDAV upload/download/content comparison/delete
  passed. Browser workflow and external-client tests remain pending. DEN public
  Fluxer HTTPS is temporarily unavailable under the BASM-first forwarding plan.
- Postal's active configuration already uses `mx`, `rp`, `routes`, `spf` and
  `track` hostnames; the import preserved signing/Rails secrets, not the old
  hostname layout. The root SPF's legacy `include:mail...` was corrected to
  `include:spf...`, preserving other TXT records. Postal's refreshed SPF, DKIM,
  MX and return-path checks all report OK. One authenticated SMTP test was
  accepted by Proton, arrived in the owner's inbox and passed received
  SPF/DKIM/DMARC checks. Its queue drained. Unauthenticated external relaying
  was rejected. Keep the existing DKIM key/selector during this migration.
- The guest OS still reports `Etc/UTC`. The wizard's application timezone does
  not set the OS timezone; verify it separately because maintenance uses the
  server clock.

Source migration bundles are under `/backup/basm-migration-20261102.*` on Mint,
with a verified copy under `/var/backups/mint-migration-20261102` in the VM.
These contain secrets and must stay access-restricted. They are outside
`/opt/basm`, so BASM's normal deployment snapshot does not include them.
The final quiesced Mint recovery bundle is
`/backup/basm-final-cutover-20261102.WYsj8x` on the source, with a checksum-verified
copy at `/var/backups/mint-final-cutover-20261102` on BASM. It includes a fresh
ERPNext database/file backup, Postal dump and protected host configuration.
It is a final rollback capture, not a second import over the working BASM data.
The Mint ERP site was put into maintenance mode for that capture.

Restic snapshots before/after import and after cutover passed full verification.
Post-cutover snapshot `d504e7cf` includes the compatibility stacks and private
vault configuration; all 27 repository packs were read successfully.
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

Mint is now cold rollback, not a parallel production server. Do not start its
old application containers alongside BASM. To roll back, first stop the
replacement writers and reconcile any data created after cutover; a power-on
alone does not reverse database or DNS changes. The old ERP site's maintenance
mode also needs explicit review before serving users again.

Before wiping Mint: complete the real kiosk heartbeat and browser workflows,
an independent encrypted backup copy and replacement-host recovery.
Retain source disks without wiping them. Remove the temporary
`/etc/sudoers.d/99-copilot-session` grant on both original hosts when maintenance
access is no longer needed.

## Post-migration acceptance tests

Use the real ERP, mail and cloud hostnames with normal HTTPS verification.
Stop if the browser reports an untrusted certificate; do not enter credentials.
Retrieve passwords privately from the handover, not logs or shared screenshots.

1. **ERPNext:** sign in as `Administrator` using the new BASM handover password.
   Confirm the imported company, customer and item. Create and delete a harmless
   draft document; do not submit invoices as a connectivity test.
2. **Nextcloud:** sign in with the BASM handover account. Upload a test file,
   download it, compare contents, then delete it.
3. **Postal:** use the imported Postal account (not necessarily the fresh BASM
   handover login). Confirm the organization, server and domain. Check its
   displayed DNS requirements and DKIM against public DNS. Only send a test
   after SMTP/worker are resumed and old delivery processing is stopped; inspect
   delivery logs and received SPF/DKIM/DMARC results. Web login alone does not
   validate mail delivery. Postal is not employee mailbox hosting.
4. **LAMP and Uptime Kuma:** from the workstation, open private SSH tunnels:

   ```sh
   ssh -N -L 18080:127.0.0.1:8080 -L 13001:127.0.0.1:3001 basm@192.168.50.20
   ```

   Visit `http://localhost:18080` for the LAMP placeholder and
   `http://localhost:13001` for Kuma. Create Kuma's administrator only if its
   first-run screen is shown, then add a monitor for an actual service hostname.
   Neither administration port should be forwarded publicly.
5. **RustDesk:** test an actual remote connection using the preserved public
   key and configured ID/relay server. A listening port is not a relay test.
6. **KeePass:** open the canonical admin KDBX through the
   [private share](keepass-sharing.md), retrieving its master password separately.
   Test save/close/reopen. Verify imported-account credentials manually: the
   generated vault may still describe fresh-install accounts.
7. **VPN and heartbeat:** test from an external network, not just LAN. Confirm
   a VPN handshake and private service access. Confirm a fresh heartbeat file
   from the real kiosk; copied files' timestamps do not prove a new heartbeat.
8. **Recovery:** back up after all migration changes, verify the encrypted
   repository, save an independent copy and run replacement-host recovery on
   an isolated test VM before declaring the migration complete.

ERP workers/scheduling and Postal delivery may intentionally remain paused
during migration. Resume them explicitly at cutover, then verify queued work
and health; do not rerun the installer merely to resume these services.
