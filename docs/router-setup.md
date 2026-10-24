# Router and Network Setup

BASM is designed for a small-business environment with a single server behind a home or office router.

For step-by-step instructions using your installation's actual ports, ask the
installer for the generated **For IT** document at
`<BASM_ROOT>/handover/for-it.txt`. The owner receives their login details in the
separate private **For the User** document. See the
[handover instructions](../README.md#owner-and-it-handover).

For local testing, do not forward any router ports. The instructions below
apply only to production installations.

## Prerequisites

- A public IP on the router or ISP-provided upstream service
- A local DHCP reservation or static private IP for the Debian host
- Administrative access to the router

## Required port forwarding

Forward the following ports to the BASM server:

- TCP 80 -> BASM host
- TCP 443 -> BASM host
- TCP 25 -> BASM host for Postal SMTP

These are the standard ports. With custom server ports, forward public TCP 80
to the selected HTTP port, TCP 443 to the selected HTTPS port, and TCP 25 to
the selected SMTP port. Also forward the selected HTTP/HTTPS ports to the same
server ports so the custom-port URLs in the handover work from outside.
Use the server's reserved private IPv4 address as every rule's destination.

Do not expose SSH by default. Prefer a configured VPN for remote administration.
WireGuard is not started automatically; only after IT has enabled it should
its selected UDP port (normally 51820) be forwarded. Keep LAMP and Uptime Kuma
private, and never forward database or Docker ports.

## DNS requirements

Create A records for:

- example.com -> public IP
- erp.example.com -> public IP
- mail.example.com -> public IP
- cloud.example.com -> public IP

Mail also needs the MX, SPF, DKIM, and DMARC records specified by Postal and
reverse DNS (PTR) arranged with the ISP. Confirm the ISP permits inbound and
outbound TCP 25 and provides a public IP without carrier-grade NAT. Postal
does not provide employee mailboxes or webmail.

## Security guidance

- Restrict SSH to a specific admin IP where possible
- Consider fail2ban or another hardening layer
- Keep router firmware updated and remove outdated port mappings
