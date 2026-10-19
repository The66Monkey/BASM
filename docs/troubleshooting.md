# BASM Troubleshooting

## Installer fails at Docker install

Check the following:

- Debian is installed and the system is up to date
- The host can reach Docker repositories
- The user is truly root or using sudo correctly

## Docker stack fails to start

Review the stack and logs:

- docker compose -f /opt/basm/docker-compose.yml config
- docker compose -f /opt/basm/docker-compose.yml logs

## Port already in use

The wizard warns before continuing. If a service still fails, check which program is listening on the port:

- ss -lntup | grep :80
- ss -lntup | grep :443

## Reverse proxy issues

- Verify that DNS points to the public IP
- Check Traefik configuration in /opt/basm/config/traefik.yml
- Confirm router forwarding is correct

## Backup issues

- check the backup directory
- confirm Restic repository initialization
- validate that the backup service can read the data paths
