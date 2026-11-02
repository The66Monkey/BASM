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

When Fluxer is selected, also forward its configured voice-media TCP and UDP
ports to the same ports on the BASM host. The values are listed in the private
IT handover. Do not forward Fluxer's internal proxy listener.

These are the standard ports. With custom server ports, forward public TCP 80
to the selected HTTP port, TCP 443 to the selected HTTPS port, and TCP 25 to
the selected SMTP port. Also forward the selected HTTP/HTTPS ports to the same
server ports so the custom-port URLs in the handover work from outside.
Use the server's reserved private IPv4 address as every rule's destination.

When Fluxer is selected, also create an A record for `chat.<domain>` and forward
its configured LiveKit voice TCP and UDP ports (normally 7881/tcp and 7882/udp).
Fluxer chat itself is served through BASM Traefik on the existing HTTP/HTTPS
ports; do not expose Fluxer’s internal services or its edge proxy directly.

## DNS requirements

Create A records for:

- example.com -> public IP
- erp.example.com -> public IP
- mail.example.com -> public IP
- cloud.example.com -> public IP
- chat.example.com -> public IP (when Fluxer is selected)

Mail also needs the MX, SPF, DKIM, and DMARC records specified by Postal and
reverse DNS (PTR) arranged with the ISP. Confirm the ISP permits inbound and
outbound TCP 25 and provides a public IP without carrier-grade NAT. Postal
does not provide employee mailboxes or webmail.

### Entering records in deSEC

The **Record set type** selector chooses A, MX, TXT or CNAME. **Subname** is
relative to your domain: for `mail.example.com` under `example.com`, enter
`mail`. For the root domain, leave Subname **blank**, not `@`.

The following example assumes the default BASM hostnames under `example.com`.
Replace `example.com` with your primary domain and `PUBLIC_IPV4` with your
current public IPv4 address. For customized hostnames, use the generated
`<BASM_ROOT>/handover/dns-records.txt` (normally
`/opt/basm/handover/dns-records.txt`).

| Record set type | Subname | Preference (MX only) | Hostname / Content / IPv4 address | TTL |
| --- | --- | --- | --- | --- |
| A | *(blank)* | | `PUBLIC_IPV4` | 3600 |
| A | `erp` | | `PUBLIC_IPV4` | 3600 |
| A | `cloud` | | `PUBLIC_IPV4` | 3600 |
| A | `mail` | | `PUBLIC_IPV4` | 3600 |
| A | `mx` | | `PUBLIC_IPV4` | 3600 |
| MX | *(blank)* | 10 | `mx.example.com.` | 3600 |
| MX | `routes` | 10 | `mx.example.com.` | 3600 |
| MX | `rp` | 10 | `mx.example.com.` | 3600 |
| TXT | `spf` | | `"v=spf1 a:mail.example.com ~all"` | 3600 |
| TXT | *(blank)* | | `"v=spf1 a mx include:spf.example.com ~all"` | 3600 |
| TXT | `rp` | | `"v=spf1 a mx include:spf.example.com ~all"` | 3600 |
| TXT | `_dmarc` | | `"v=DMARC1; p=none"` | 3600 |
| CNAME | `psrp` | | `rp.example.com.` | 3600 |
| CNAME | `track` | | `mail.example.com.` | 3600 |

deSEC requires **surrounding double quotation marks for TXT content**; enter
them as shown. MX Preference is a separate field: enter `10` there, not as
part of the Hostname. The trailing dot marks an absolute DNS hostname.
Only add `chat` (or your configured Fluxer hostname) if BASM Fluxer is selected.

Publish the exact DKIM subname and quoted TXT content shown in Postal's domain
DNS setup; the selector and key are deployment-specific. Retain the old DKIM
selector while the old mail system is still in use. Have only **one SPF record
per name**: edit an existing SPF record rather than adding a second. If other
providers also send mail for the domain, preserve their authorization in that
single policy. `p=none` monitors DMARC; it does not enforce rejection.

Do not wipe the zone or delete NS, existing mail, or certificate-challenge
records during migration. Export the existing records before making changes.
Adding MX records can change inbound delivery even before router forwarding
changes, so coordinate mail DNS with the migration.

### Sharing a domain with DEN

BASM's non-static updater manages A records for the root, ERP, mail, cloud and
`mx`, plus Fluxer only when selected. DEN manages `home`, `media`, `photos`,
`files`, `git`, and its enabled `chat`/`downloads` records. Separate ownership
lets both update the same zone; avoid configuring both to manage the same name.
Use separate API tokens with record-scoped permissions where possible.

DDNS updates public addresses, not the complete Postal DNS configuration above.
One public IPv4 also does not route HTTPS to different internal servers by
hostname: that needs an explicitly configured shared reverse proxy, or private
DEN access through its VPN. Preserve the old server and forwarding until the
replacement has been tested and cutover is approved.

## DNS and server access

Do not expose SSH by default. Prefer a configured VPN for remote administration.
WireGuard is not started automatically; only after IT has enabled it should
its selected UDP port (normally 51820) be forwarded. Keep LAMP and Uptime Kuma
private, and never forward database or Docker ports.

SSH access is limited to key-based authentication with the standard Debian
configuration; the installer does not modify SSH settings.

Production LAMP and Uptime Kuma default to loopback-only listeners. Use SSH
tunnels, or explicitly configure a private LAN `MANAGEMENT_BIND_ADDRESS`.
Existing module bindings are not changed until those modules are regenerated.
Public ERP, cloud and Postal routes remain public; BASM does not copy DEN's
private-home-app firewall policy onto a business server.
