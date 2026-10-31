# Operations Guide

Day-to-day procedures for a running BASM server. Use `/opt/basm-local` in place
of `/opt/basm` for local installs; a custom `BASM_ROOT` uses its own tree.

## Owner and IT handover

Every completed install generates two plain-text documents with the actual
addresses, selected ports, and initial credentials for that deployment:

- **For the User**: service addresses, usernames and initial passwords, backup
  recovery details, and a separate technical credentials section. It identifies
  accounts that need manual setup and includes space for the IT contact.
- **For IT**: a numbered checklist covering router login, reserving the server's
  network address, DNS, exact TCP/UDP forwarding rules, mail setup, service
  checks, backups, and secure handover. Local testing has separate instructions
  that explicitly prohibit router forwarding.

```sh
sudo less /opt/basm/handover/for-the-user.txt
sudo less /opt/basm/handover/for-it.txt
```

The `handover/` directory has mode `0700` and both documents mode `0600`.
Re-running the installer or upgrading modules regenerates them from the saved
configuration. Passwords changed inside applications must be recorded
separately; BASM cannot retrieve them.

## Dynamic IP (non-static installs)

Answer `non-static` at the public IP question and provide a deSEC API token.
BASM installs `/etc/cron.d/basm-ddns-*`, which checks the public IPv4 every
4 hours and updates the deSEC A records for the primary, ERP, mail, and cloud
hostnames when it changes. External access can be down for up to about 4 hours
after a change. All hostnames must belong to the same deSEC domain. Changes are
logged to `<BASM_ROOT>/logs/ddns.log`. Expect possible mail deliverability
problems on a dynamic IP.

## Automatic application updates

The updater runs as root at **03:00 on January 1 and July 1** using the server's
clock. Missed runs are not caught up, and updates can briefly interrupt
services. Before changing applications it dumps all three databases and creates
an encrypted Restic snapshot; if either fails it stops. Failures are logged,
with no automatic rollback or external notification.

It updates images within their configured tags only: not Debian packages, the
BASM checkout, or version-pinned applications. Pinned versions need periodic
IT review. Six-month updates are not a substitute for urgent security fixes.

Logs: `<BASM_ROOT>/logs/automatic-updates.log`.

Disable automatic runs (survives installer reruns); remove the file to re-enable:

```sh
sudo touch /opt/basm/config/disable-auto-updates
```

For quarterly runs, change the cron month field from `1,7` to `1,4,7,10` in
this deployment's file under `/etc/cron.d/`; installer reruns restore the
six-month schedule.

For an immediate manual update after confirming a usable backup, run
`sudo ./update.sh` from the checkout. Manual runs share the overlap lock but do
not create the pre-update snapshot.

## Upgrading and promoting

- `sudo ./install.sh --full` adds LAMP, WireGuard, and Uptime Kuma to an
  existing install without touching core services, data, or credentials.
- `sudo ./install.sh --module fluxer` adds the optional Fluxer chat stack behind
  BASM Traefik, including its persistent data, database dumps, and update path.
- `sudo ./install.sh --promote` replaces a local test install with a fresh
  production install, carrying over organization settings and module selection.

Neither path upgrades system packages or re-downloads cached Docker images. See
[installation.md](installation.md#upgrading-from-basic-to-full) and
[promoting](installation.md#promoting-a-local-test-install-to-production).
