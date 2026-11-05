# Router and Network Setup

BASM is designed for a small-business network and can run directly on a server
or in a Debian VM behind a router or DEN edge.

For step-by-step instructions using your installation's actual ports, ask the
installer for the generated **For IT** document at
`<BASM_ROOT>/handover/for-it.txt`. The owner receives their login details in the
separate private **For the User** document. See the
[handover instructions](../README.md#owner-and-it-handover).

For local testing, do not forward any router ports. The instructions below
apply only to production installations.

## Prerequisites

- A reachable public IPv4 on the router or an upstream service; dynamic IPv4 is supported
- A local DHCP reservation or static private IP for the Debian host
- Administrative access to the router

## Required port forwarding

For a single BASM server directly behind the router, forward:

- TCP 80 -> BASM host
- TCP 443 -> BASM host
- TCP 25 -> BASM host for Stalwart SMTP

For Thunderbird or other mail clients connecting from outside the LAN/VPN,
also forward TCP 465 (submission) and TCP 993 (IMAPS) to BASM. For LAN/VPN-only
mail clients, keep those ports private and use private DNS so the canonical
`mx.<domain>` hostname resolves to BASM's LAN address.

When Fluxer is selected, also forward its configured voice-media TCP and UDP
ports to the same ports on the BASM host. The values are listed in the private
IT handover. Do not forward Fluxer's internal proxy listener.

### BASM in a VM or behind DEN

BASM is supported inside its own Debian VM. Ports used by separate guests do
not conflict at the guest operating-system level, and the installer can only
detect listeners inside the BASM guest. Public router ports are a separate
constraint: each forwarded port can target only one LAN address unless an
explicit proxy or gateway routes it.

For a BASM VM behind a DEN edge, use the public edge for TCP 80/443 and route
the BASM web hostnames through that edge to the BASM guest. Forward public TCP
25 directly to the BASM guest for Stalwart; SMTP is not HTTP and must not go
through an HTTP reverse proxy. Forward TCP 465/993 directly only if off-site
mail-client access is wanted. Keep BASM's guest IP reserved in the router.

Example: TCP 80/443 -> DEN's LAN address; TCP 25 -> BASM VM's LAN address.
Do not also forward TCP 80/443 directly to BASM while they are assigned to
DEN. If BASM owns the public web ports instead, forward them to BASM and do not
assign those same ports to DEN. See [BASM behind a separate HTTPS edge](operations.md#basm-behind-a-separate-https-edge)
for the edge's TLS and client-address requirements.

These are the standard ports. With custom server ports, forward public TCP 80
to the selected HTTP port, TCP 443 to the selected HTTPS port, and TCP 25 to
the selected Stalwart SMTP port. Forward TCP 465 and TCP 993 only when
off-network mail-client access is intended. Also forward the selected
HTTP/HTTPS ports to the same server ports so the custom-port URLs in the
handover work from outside.
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
- mx.example.com -> public IP
- chat.example.com -> public IP (when Fluxer is selected)

Mail also needs the MX, SPF, DKIM, and DMARC records specified in the generated
DNS handover. Dynamic IPv4 is supported: BASM's default deSEC updater refreshes
its A records every 15 minutes. Stalwart handles inbound and outbound SMTP,
user mailboxes, IMAP and authenticated SMTP submission. Confirm the network
path permits inbound and outbound TCP 25 and provides a reachable public IP
without carrier-grade NAT. PTR is controlled by the IP address-range owner,
not deSEC; lack of PTR access does not prevent hosting mail but can affect
outbound delivery.

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
| A | *(blank)* | | `PUBLIC_IPV4` | 300 |
| A | `erp` | | `PUBLIC_IPV4` | 300 |
| A | `cloud` | | `PUBLIC_IPV4` | 300 |
| A | `mail` | | `PUBLIC_IPV4` | 300 |
| A | `mx` | | `PUBLIC_IPV4` | 300 |
| CNAME | `autoconfig` | | `mx.example.com.` | 3600 |
| CNAME | `autodiscover` | | `mx.example.com.` | 3600 |
| MX | *(blank)* | 10 | `mx.example.com.` | 3600 |
| TXT | *(blank)* | | `"v=spf1 mx -all"` | 3600 |
| TXT | `_dmarc` | | `"v=DMARC1; p=none; rua=mailto:postmaster@example.com"` | 3600 |

deSEC requires **surrounding double quotation marks for TXT content**; enter
them as shown. MX Preference is a separate field: enter `10` there, not as
part of the Hostname. The trailing dot marks an absolute DNS hostname.
The A-record TTL is 300 seconds so dynamic address changes propagate sooner.
Only add `chat` (or your configured Fluxer hostname) if BASM Fluxer is selected.

Publish the exact DKIM record shown by Stalwart. Retain old DKIM selectors
during migration. Have only
**one SPF record per name**: edit an existing SPF record rather than adding a
second. `p=none` monitors DMARC; it does not enforce rejection.

Do not wipe the zone or delete NS, existing mail, or certificate-challenge
records during migration. Export the existing records before making changes.
Adding MX records can change inbound delivery even before router forwarding
changes, so coordinate mail DNS with the migration.

### Sharing a domain with DEN

BASM's dynamic-IP updater manages A records for the root, ERP, mail, cloud and
`mx`, plus Fluxer only when selected. DEN manages `vpn`, `home`, `media`, `photos`,
`files`, `git`, and its enabled `chat`/`downloads` records. Separate ownership
lets both update the same zone; avoid configuring both to manage the same name.
Use separate API tokens with record-scoped permissions where possible.

DDNS updates public addresses, not the complete mail DNS configuration above.
One public IPv4 also does not route HTTPS to different internal servers by
hostname: that needs an explicitly configured shared reverse proxy, or private
DEN access through its VPN. Preserve the old server and forwarding until the
replacement has been tested and cutover is approved.

### AdGuard administration with DEN

BASM does not install a DNS resolver or own AdGuard. When DEN provides shared
DNS/HTTPS infrastructure, use `https://dns.example.com` for the AdGuard interface,
with your configured domain. Add an exact **private AdGuard rewrite** from
`dns.example.com` to DEN's LAN address; keep it out of BASM's public DDNS records.
The DEN edge restricts access to LAN/VPN clients and retains AdGuard's login.

Use that interface to manage LAN filtering and inspect device requests.
Moving DHCP DNS to AdGuard does not migrate the router's blocking rules.
Transfer reviewed rules there, preferably scoped to a device's reserved IP.
Neither project installs a blanket vendor/TV blocking list.
See DEN's [AdGuard setup](https://github.com/The66Monkey/DEN/blob/main/docs/infrastructure.md#adguard-administration-dnsexamplecom)
for HTTPS, private DNS, VPN records and optional device-specific examples.

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
Public ERP, cloud and mail routes remain public; BASM does not copy DEN's
private-home-app firewall policy onto a business server.
