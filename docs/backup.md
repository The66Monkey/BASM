# Backup and Recovery

At **02:00 server time**, BASM briefly pauses applications, takes fresh database
dumps, stops databases, and creates one encrypted Restic snapshot. Previously
running services are restarted even if the backup fails. Updates use the same
backup procedure. Allow a maintenance window proportional to your data size.

Snapshots cover the whole deployment: application files, cold database data,
logical dumps, configuration, credentials, handovers, installed maintenance
code, and every optional module. Fluxer's upstream archive and manager are
saved inside the deployment too. Docker image digests are recorded so recovery
does not silently install newer images. Logs and the backup repository are excluded.
Stalwart's mailbox data and configuration are included in the cold snapshot;
its embedded database is stopped with the other writers and needs no MariaDB dump.
External data linked by symlinks is not followed; keep supported data beneath
the deployment root or arrange its backup explicitly.

The default repository is `/var/backups/basm/restic` (local mode:
`/opt/basm-local/backups/restic`). The Restic password is in `config/basm.env`.
The backup filesystem identity is recorded;
a missing or changed mount stops the job instead of writing onto the OS disk.

For a production VM, a dedicated directory on a separate host-attached disk can
be mounted inside the guest with virtiofs. See
[production VM storage](virtual-machines.md) for provisioning, startup ordering,
safe migration of an existing repository, and recovery acceptance tests.

### Adopting a deliberately changed mount

After copying the existing repository to separate mounted storage **at the
same configured guest path**, run `sudo basm backup-adopt-mount`. It requires
a complete snapshot for the current deployment and fully verifies repository
data before atomically updating the saved filesystem identity; the old identity
is retained privately. It does not copy data, configure mounts, create a
repository or remove the original copy. Failures leave the identity unchanged.
Use the [locked migration procedure](virtual-machines.md#moving-an-existing-vm-disk-repository),
not this command to dismiss an unexpected mount failure.

## Routine commands

```sh
sudo basm backup
sudo basm snapshots
sudo basm verify-backup
sudo basm restore SNAPSHOT_ID /srv/basm-restore-check
```

Use `--root /opt/basm-local` before the command for a local installation.
Restores require an explicit snapshot ID and a new staging directory outside
live data and backups. Restic verifies restored contents; BASM validates the
manifest. Nothing is written over the running deployment. Inspect actual files
and accounts on a disposable recovery host before relying on recovery.

Nightly pruning retains 7 daily, 4 weekly and 12 monthly snapshots.
`sudo basm prune` applies the same policy manually. Legacy partial snapshots
are left untouched; only complete `basm-v2` snapshots qualify for BASM recovery.

## Replacement host

Save a small private recovery kit to another filesystem:

```sh
sudo basm recovery-kit /media/recovery-usb
```

On a fresh Debian host, restore the repository to its original path.
Keep the original domain, deployment path and backup path. Do **not** run the
normal installer and do not create the deployment directory.

```sh
cd /media/recovery-usb/basm-recovery-kit
sudo bash recover.sh ./basm.env SNAPSHOT_ID
```

Recovery verifies a staged restore, refuses existing data/containers, reinstates
saved image versions, restores Fluxer when selected, and reinstalls maintenance
jobs and takes a fresh complete backup. Internet access is needed for packages
and saved images. Existing manual
host configuration (firewall, SSH, enabled WireGuard server, router and DNS)
remains an IT responsibility.

### Manually migrated services

BASM manages only the installer modules listed in `BASM_MODULES`. Other Compose
stacks under `<BASM_ROOT>/modules/` are not stopped, updated, or health-checked
by BASM maintenance. Their files under `<BASM_ROOT>` may be present in a
filesystem snapshot, but BASM does not make application-specific database
dumps or guarantee a consistent backup for those services. Test each service
after recovery. Keep external source migration bundles and locally
built/imported container images in a separate protected recovery kit; a
local-only image ID cannot be pulled from a registry.

For managed services, BASM records registry image digests. If Docker no longer
reports registry metadata for a running image, BASM retains the Compose digest
already configured for that service. An unpinned local image still blocks a
complete backup.
See the [migration guide](migration.md#manually-migrated-services) for DNS/VPN
and untrusted heartbeat integration considerations.

After a bad update, preserve failed data and use a replacement host or an
administrator-reviewed recovery procedure. Never downgrade images over migrated
databases, delete business data, or remove an interruption marker merely to retry.
