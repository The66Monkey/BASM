#!/usr/bin/env python3
import json
import shlex
import sys

KEYS = set("""
DEPLOYMENT_MODE BIND_ADDRESS BASM_CONTAINER_PREFIX PORT_PROFILE COMPANY_NAME
PRIMARY_DOMAIN ADMIN_EMAIL TIMEZONE HTTP_PORT HTTPS_PORT SSH_PORT LAMP_PORT
UPTIME_KUMA_PORT WIREGUARD_PORT RUSTDESK_NAT_PORT RUSTDESK_ID_PORT RUSTDESK_RELAY_PORT
FLUXER_PROXY_PORT FLUXER_VOICE_TCP_PORT FLUXER_VOICE_UDP_PORT ERP_URL MAIL_URL CLOUD_URL
IP_MODE DESEC_TOKEN BACKUP_LOCATION BASM_ROOT BASM_MODULES DB_ROOT_PASSWORD
ERP_ADMIN_PASSWORD NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_DB_PASSWORD
SMTP_BIND_ADDRESS SMTP_PORT WEB_PROTOCOL RESTIC_PASSWORD FLUXER_DOMAIN MANAGEMENT_BIND_ADDRESS
MAILBOX_HOSTNAME MAILBOX_BIND_ADDRESS MAILBOX_SETUP_BIND_ADDRESS MAILBOX_SETUP_PORT
MAILBOX_SUBMISSION_PORT MAILBOX_IMAPS_PORT
ERP_EXAMPLES
""".split())
LEGACY_KEYS = {"POSTAL_DB_PASSWORD", "POSTAL_ADMIN_PASSWORD", "POSTAL_RAILS_SECRET", "POSTAL_WEB_PROTOCOL"}


def read_environment(path):
    values = {}
    with open(path) as file:
        for number, line in enumerate(file, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, raw = line.partition("=")
            if not separator or key not in KEYS | LEGACY_KEYS or key in values:
                raise ValueError(f"Unknown, duplicate or invalid setting on line {number}")
            parts = shlex.split(raw, comments=False, posix=True)
            if len(parts) > 1:
                raise ValueError(f"Invalid value on line {number}")
            value = parts[0] if parts else ""
            if any(character in value for character in "\x00\r\n"):
                raise ValueError(f"Invalid control character on line {number}")
            values[key] = value
    return values


if __name__ == "__main__":
    json.dump(read_environment(sys.argv[1]), sys.stdout)
