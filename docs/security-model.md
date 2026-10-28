# Security Model

## Secrets

- Credentials and deployment values are generated at install time and stored
  outside the repository in `<BASM_ROOT>/config/basm.env` with mode `0600`.
- The DDNS API token, if used, is stored only in that file.
- WireGuard keys and prepared WireGuard configs are secrets (`0600`) and are
  kept across reruns.
- Postal's mounted config and signing key are readable by Postal's non-root
  container account but are not world-readable.
- The installation summary lists account names only. Passwords are never
  printed in the summary or installer log.

## Handover documents

`<BASM_ROOT>/handover/` is mode `0700`; both documents are `0600`. They contain
credentials and must be delivered securely to the owner and IT helper.

## Network exposure

- Production: Traefik terminates TLS with Let's Encrypt and redirects HTTP to
  HTTPS. Public TCP 443 must reach Traefik for certificate validation.
- Local mode binds to `127.0.0.1` or a private RFC 1918 address. Wildcard and
  public bindings are rejected. Local HTTP is unencrypted; never forward its
  ports on a router.
- Application containers are reachable only on the private Compose network.
- BASM does not change SSH settings or configure firewalls or routers.
- WireGuard only generates configuration; it does not start a VPN server.

## Backups and updates

- Restic repositories are encrypted. The default repository is on the host and
  does not protect against disk or host loss; an off-host copy is required.
- Database dumps are root-only.
- Automatic updates abort if the pre-update dump or snapshot fails, and use a
  lock to prevent overlapping runs.
- Updates do not patch Debian packages or move pinned application versions.

## Production mail

Reserved addresses such as `admin@example.com` are rejected as the Let's Encrypt
contact. Real mail delivery needs correct MX/SPF/DKIM/DMARC records, a stable
IP with reverse DNS, and a provider that permits TCP 25.
