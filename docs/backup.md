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
External data linked by symlinks is not followed; keep supported data beneath
the deployment root or arrange its backup explicitly.

The default repository is `/var/backups/basm/restic` (local mode:
`/opt/basm-local/backups/restic`). A local copy alone does not protect against
disk loss or theft. Keep an independent encrypted off-host copy and the Restic
password from `config/basm.env`. The backup filesystem identity is recorded;
a missing or changed mount stops the job instead of writing onto the OS disk.

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

On a fresh Debian host, restore the off-host repository to its original path.
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

Compose stacks placed under `<BASM_ROOT>/modules/*/docker-compose.yml` are
discovered by maintenance and recovery. Their in-tree bind-mounted data is
included in snapshots, but this does not add application-specific database
dumps or health checks. Test each service after recovery. Keep external source
migration bundles and any locally built/imported container images in a separate
protected recovery kit; a local-only image ID cannot be pulled from a registry.
See the [migration checkpoint](operations.md#home-lab-migration-checkpoint-2026-11-02)
for the manually migrated DNS/VPN and heartbeat stacks.

After a bad update, preserve failed data and use a replacement host or an
administrator-reviewed recovery procedure. Never downgrade images over migrated
databases, delete business data, or remove an interruption marker merely to retry.
