# Router and Network Setup

BASM is designed for a small-business environment with a single server behind a home or office router.

## Prerequisites

- A public IP on the router or ISP-provided upstream service
- A local DHCP reservation or static private IP for the Debian host
- Administrative access to the router

## Required port forwarding

Forward the following ports to the BASM server:

- TCP 80 -> BASM host
- TCP 443 -> BASM host
- TCP 22 -> BASM host if SSH access from outside the LAN is required

## DNS requirements

Create A records for:

- example.com -> public IP
- erp.example.com -> public IP
- mail.example.com -> public IP
- cloud.example.com -> public IP

## Security guidance

- Restrict SSH to a specific admin IP where possible
- Consider fail2ban or another hardening layer
- Keep router firmware updated and remove outdated port mappings
