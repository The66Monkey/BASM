# BASM Troubleshooting

## Installer fails at Docker install

Check the following:

- Debian is installed and the system is up to date
- The host can reach Docker repositories
- The user is truly root or using sudo correctly

If APT reports `Permission denied` reading `docker.gpg`, older installers created
the public repository files with root-only permissions. Repair them with:

```sh
sudo chmod 755 /etc/apt/keyrings
sudo chmod 644 /etc/apt/keyrings/docker.gpg /etc/apt/sources.list.d/docker.list
sudo apt-get update
```

Current installers set these permissions before installing Docker, including on
retries. Do not disable repository signature verification.

## Docker stack fails to start

Review the stack and logs:

- docker compose -f /opt/basm/docker-compose.yml config
- docker compose -f /opt/basm/docker-compose.yml logs
- docker compose -f /opt/basm/docker-compose.yml ps
- docker compose -f /opt/basm/docker-compose.yml logs erpnext-create-site postal-initialize

## Port already in use

The wizard warns before continuing. If a service still fails, check which program is listening on the port:

- ss -lntup | grep :80
- ss -lntup | grep :443

For Postal's SMTP port, run `sudo ss -ltnp 'sport = :25'`. Debian may already
have Exim installed for local mail delivery. If it is not needed, explicitly
stop and disable it before retrying; the installer does not stop existing mail
services automatically.

## Reverse proxy issues

- Verify that DNS points to the public IP
- Check Traefik configuration in /opt/basm/config/traefik.yml
- Confirm router forwarding is correct

## Backup issues

- check `/var/backups/basm/restic` or `/opt/basm-local/backups/restic`
- verify complete snapshots with `sudo basm snapshots` and `sudo basm verify-backup`
- confirm the database dump files exist under `/opt/basm/data/db-backups`
- read `/opt/basm/logs/backup.log` and run `sudo basm check`
- check that the configured backup filesystem is mounted; a changed identity
  is an error, not a reason to delete the repository or its saved identity

## Interrupted update

Read `logs/automatic-updates.log`, `logs/last-failure`, and application logs.
`config/update-in-progress` deliberately blocks unsafe retries. Do not remove
it to force a retry or downgrade images over migrated databases. Preserve data
and use the pre-update snapshot with the [recovery procedure](backup.md).

## Management service unavailable from the LAN

New production LAMP and Uptime Kuma listeners are loopback-only by default.
Use an SSH tunnel or explicitly configure a private `MANAGEMENT_BIND_ADDRESS`
and regenerate that module. Do not expose these HTTP ports publicly.
