# Backup Strategy

BASM uses a simple and understandable backup model. The default strategy uses Restic with a local repository under /var/backups/basm and keeps the backup configuration in a human-readable form.

## Recommended backup flow

1. Snapshot the BASM data directories.
2. Store the repository on local disk or on an external destination.
3. Back up configuration files, Docker data, and database volumes as part of the same schedule.
4. Copy the repository to an offsite or removable storage medium on a regular basis.

## Example preservation approach

- Data: /opt/basm/data
- Global configuration: /opt/basm/config
- Backups: /var/backups/basm
- External copy: USB drive, NAS, or remote object storage

## Recovery plan

To recover from disaster:

1. Reinstall Debian and BASM.
2. Restore the backup repository.
3. Recreate containers and ensure Docker volumes are mounted correctly.
4. Validate services and URLs.

## Notes

The repository is intentionally simple and can be upgraded to more advanced backup policies later without rewriting the rest of BASM.
