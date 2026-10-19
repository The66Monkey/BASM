# BASM Installation Guide

This document explains how to install BASM on a fresh Debian server and bring the stack online with minimal operational overhead.

## Requirements

- Fresh Debian 12 or compatible Debian-based host
- Root access or sudo privileges
- Public static IP or routed network access
- Domain names for ERP, mail, and cloud subdomains
- A router that allows port forwarding for HTTP and HTTPS traffic

## Steps

1. Copy the BASM project to the Debian host.
2. Review the defaults in config/defaults.env.
3. Run the installer as root or with sudo.
4. Complete the configuration wizard.
5. Select the desired modules.
6. Review the generated summary in output/installation-summary.txt.

## Installer behavior

The installer does the following:

- Detects Debian and verifies root access
- Installs Docker and the Docker Compose plugin
- Installs common requirements and base tooling
- Creates the BASM directory structure
- Generates environment values in config/basm.env
- Deploys the selected modules
- Creates the post-installation summary

## Common maintenance

- Use update.sh to pull new images and recreate services
- Use uninstall.sh to remove the stack and generated volumes
- Keep backups in a dedicated storage location outside the live service path

## Suggested defaults

- ERP URL: erp.domain.tld
- Mail URL: mail.domain.tld
- Cloud URL: cloud.domain.tld
- Backup directory: /var/backups/basm

## Recovery note

BASM is intentionally modular. If one service fails, it can be repaired or replaced without restarting the entire stack.
