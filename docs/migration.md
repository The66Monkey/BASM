# Migration and Acceptance Guide

For routine commands, credentials and schedules, see [operations](operations.md).
Keep deployment addresses, inventory, backup identifiers, logs and acceptance
results in a private operator record, not the public source repository.

## Migrating a hand-built server

`recover.sh` accepts complete BASM-format backups, not an arbitrary legacy
installation. First save native application backups, configuration,
encryption/signing keys, image versions and a database-consistent RustDesk
SQLite backup. Keep a second verified copy before importing into a fresh BASM
installation. Never copy a running database's raw files or restore another
MariaDB version's system tables over the replacement.

Restore ERPNext's database and public/private files, preserve its encryption
key, and run migrations for the target application version. Restore Postal's
application databases and signing/Rails secrets, retaining BASM's database
connection settings and intended DNS hostname layout. Preserving RustDesk's
server keys avoids changing the identity configured on its clients. Imported
application logins may differ from the fresh-install handover; update the
private vault accordingly.

Leave background mail delivery and ERP scheduling paused until cutover to avoid
duplicate processing. BASM's health check should fail while required services
are stopped: do not suppress it. Successful one-shot initialization containers
can remain exited with code 0.

At cutover, stop source writers, capture and verify a final recovery bundle,
then explicitly resume replacement workers, SMTP and site scheduling. Verify
actual jobs and delivery, not just container startup. Do not rerun the installer
to resume services. Keep source disks intact for cold rollback; do not restart
source applications alongside the replacement. Rollback must reconcile new
data, maintenance mode, DNS and forwarding, not merely power on the old host.

## Manually migrated services

Additional Compose stacks under `<BASM_ROOT>/modules/` are manual integrations,
not new supported installer modules. See [backup coverage](backup.md#manually-migrated-services).
Keep external migration bundles and local-only images in a protected recovery
kit; neither is recovered merely by restoring a Compose file.

For DNS/VPN migration, preserve keys and peer addresses when appropriate, but
verify endpoint names, UDP forwarding and real external handshakes. Use exact
private DNS rewrites for each service, not a whole-domain override that hides
other servers. A dedicated public VPN hostname must not be rewritten privately.
See [DNS ownership](router-setup.md#sharing-a-domain-with-den).

Untrusted third-party display devices must not hold administrator credentials,
vaults, private keys or home VPN profiles. An unauthenticated heartbeat is only
an attacker-controlled IP-discovery hint, never a trusted identity or authority
to run commands. Keep credentials on trusted administrator devices, retain SSH
host-key verification and avoid agent forwarding. Verify both a manual request
and subsequent scheduled updates; remote desktop access does not provide VPN
routing for a separate heartbeat process.

## Post-migration acceptance tests

Use actual service hostnames with normal HTTPS verification. Never enter
credentials through an untrusted certificate warning. Retrieve passwords
privately, not from shared logs or screenshots.

1. **ERPNext:** sign in, verify imported records, create/delete a harmless draft
   and confirm a background job completes with site scheduling enabled.
2. **Nextcloud:** sign in, upload/download a test file, compare contents and delete
   it. Check maintenance mode and database-upgrade status.
3. **Postal:** verify the imported organization/server/domain and refreshed SPF,
   DKIM, MX and return-path checks. Compare active hostname settings with DNS;
   preserve existing signing keys. After stopping old delivery processing, send
   one authorized test to a controlled external mailbox. Confirm queue drainage,
   recipient receipt and received SPF/DKIM/DMARC results. Also verify
   unauthenticated external relay is rejected. Postal is not mailbox hosting.
4. **Private management:** use SSH tunnels for LAMP and Uptime Kuma. Do not
   publicly forward their administration ports. For example, replacing
   `SERVER_LAN_IP` with the server address:

   ```sh
   ssh -N -L 18080:127.0.0.1:8080 -L 13001:127.0.0.1:3001 basm@SERVER_LAN_IP
   ```

5. **RustDesk:** make an actual remote connection using the preserved public
   key and configured ID/relay server; listening ports alone are insufficient.
6. **KeePass:** test canonical-file save/close/reopen through the
   [private share](keepass-sharing.md). Reconcile imported account credentials.
7. **Networking:** test LAN without VPN and external VPN reconnect. Confirm the
   private app addresses, public VPN endpoint and trusted hostname certificates.
   Verify any kiosk's recurring heartbeat separately.
8. **Recovery:** take and verify a fresh encrypted backup, keep an independent
   off-host copy and test replacement-host recovery on an isolated VM. Confirm
   manual host settings, share access and local-only images can be restored.
9. **Closeout:** retain source disks during a soak period, review OS timezone
   for maintenance schedules, and remove temporary maintenance access grants.

Keep the migration open until these checks are recorded privately. Working web
interfaces and a backup on the same physical host are not recovery sign-off.
