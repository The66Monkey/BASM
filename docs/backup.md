# Backup Strategy

BASM runs a Restic container that initializes an encrypted repository and snapshots application files, configuration, and scheduled MariaDB dumps once per day. The default repository is `/var/backups/basm/restic` in production and `/opt/basm-local/backups/restic` in local mode. The repository password is stored in the root-only `config/basm.env` file under the BASM data root.

## Recommended backup flow

1. Verify the daily snapshot with `docker compose -f /opt/basm/docker-compose.yml exec restic-backup restic snapshots`.
2. Copy the repository to an offsite or removable storage medium on a regular basis.
3. Test restores before relying on the repository.

## Example preservation approach

- Data: `/opt/basm/data`
- Global configuration and secrets: `/opt/basm/config`
- Database dumps: `/opt/basm/data/db-backups`
- Backups: `/var/backups/basm/restic`
- External copy: USB drive, NAS, or remote object storage

## Recovery plan

To recover from disaster:

1. Reinstall Debian and BASM.
2. Restore both the Restic repository and the root-only BASM config file.
3. Recreate containers and restore the snapshots.
4. Restore database dumps and validate services and URLs.

## Notes

The repository is local to the host by default. A disk failure can destroy both the live data and its backups, so configure an external copy for real disaster recovery. Retention is seven daily, four weekly, and twelve monthly snapshots.
