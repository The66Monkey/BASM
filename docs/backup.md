# Backup Strategy

BASM runs a Restic container that initializes an encrypted repository and snapshots application files, configuration, and database dumps once per day. Fluxer PostgreSQL is dumped to `<BASM_ROOT>/data/fluxer/db-backups`; its service data and root-only module `.env` are included in Restic as well. The default repository is `/var/backups/basm/restic` in production and `/opt/basm-local/backups/restic` in local mode. The repository password is stored in the root-only `config/basm.env` file under the BASM data root.

## Backup verification and recovery

1. Verify the daily snapshot with `docker compose -f /opt/basm/docker-compose.yml exec restic-backup restic snapshots`.
2. Copy the repository (by default `/var/backups/basm/restic` or `/opt/basm-local/backups/restic`) to external storage before any disaster scenario occurs.
3. Test recovery with `docker compose exec restic-backup restic restore <snapshot-id> --target /tmp/test-restore` and verify the recovered files.

## Example preservation approach

- Data: `/opt/basm/data`
- Global configuration and secrets: `/opt/basm/config`
- Database dumps: `/opt/basm/data/db-backups`
- Fluxer data, PostgreSQL dumps, and setup secrets: `/opt/basm/data/fluxer` and `/opt/basm/modules/fluxer/.env`
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
