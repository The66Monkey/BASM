#!/usr/bin/env python3

import os
from pathlib import Path
import secrets
import string
import sys
import tempfile

from pykeepass import PyKeePass, create_database


def sync(root, values):
    config = root / "config"
    config.mkdir(parents=True, exist_ok=True)
    vault_directory = root / "vaults" / "admin"
    if vault_directory.is_symlink() or (root / "vaults").is_symlink():
        raise ValueError("Symlink vault directories are not supported")
    vault_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    database = vault_directory / "credentials.kdbx"
    legacy_database = config / "credentials.kdbx"
    master_file = config / "keepass-master-password"
    if master_file.is_symlink() or database.is_symlink():
        raise ValueError("Symlink credential files are not supported")
    if (database.exists() or legacy_database.exists()) and not master_file.exists():
        raise ValueError("Existing database has no saved master password")
    if legacy_database.is_symlink():
        raise ValueError("Symlink legacy database is not supported")
    if legacy_database.exists():
        if legacy_database.with_name(legacy_database.name + ".lock").exists():
            raise ValueError("Close the legacy KeePass database before migration")
        if database.exists():
            raise ValueError("Both legacy and admin databases exist; resolve manually")
        # Keep a private rollback copy before moving the canonical vault.
        backup = config / "credentials.kdbx.pre-share"
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(legacy_database.read_bytes())
        legacy_database.rename(database)
    if not master_file.exists():
        alphabet = string.ascii_letters + string.digits
        while True:
            master = "".join(secrets.choice(alphabet) for _ in range(32))
            if (any(char.isupper() for char in master)
                    and any(char.islower() for char in master)
                    and any(char.isdigit() for char in master)):
                break
        descriptor = os.open(master_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as output:
            output.write(master + "\n")
    os.chmod(master_file, 0o600)
    master = master_file.read_text().rstrip("\n")
    if not master:
        raise ValueError("Empty master password")
    lock_file = database.with_name(database.name + ".lock")
    if lock_file.exists():
        raise ValueError("Close KeePassXC before updating the admin vault")
    original = database.read_bytes() if database.exists() else None
    owner = database.stat() if database.exists() else None
    descriptor, temporary_name = tempfile.mkstemp(prefix=".credentials-", suffix=".kdbx", dir=vault_directory)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        vault = PyKeePass(database, password=master) if database.exists() else create_database(temporary, password=master)
        group = vault.find_groups(name="BASM", first=True)
        if group is None:
            group = vault.add_group(vault.root_group, "BASM")

        def add(title, username="", password="", url="", notes=""):
            entry = vault.find_entries(title=title, group=group, first=True)
            if entry is None:
                entry = vault.add_entry(group, title, username, password, url=url, notes=notes)
            return entry

        scheme = "http" if values["DEPLOYMENT_MODE"] == "local" else "https"
        port = values["HTTP_PORT"] if scheme == "http" else values["HTTPS_PORT"]
        add("ERPNext administrator", "Administrator", values["ERP_ADMIN_PASSWORD"], f'{scheme}://{values["ERP_URL"]}:{port}')
        add("Nextcloud administrator", values["NEXTCLOUD_ADMIN_USER"], values["NEXTCLOUD_ADMIN_PASSWORD"], f'{scheme}://{values["CLOUD_URL"]}:{port}')
        add("ERPNext database root", "root", values["DB_ROOT_PASSWORD"], notes="Database host: erp-db")
        add("Nextcloud database root", "root", values["DB_ROOT_PASSWORD"], notes="Database host: nextcloud-db")
        add("Nextcloud application database", "nextcloud", values["NEXTCLOUD_DB_PASSWORD"], notes="Database: nextcloud; host: nextcloud-db")
        add("Restic backup encryption", password=values["RESTIC_PASSWORD"], notes=f'Repository: {values["BACKUP_LOCATION"]}/restic')
        if values["DESEC_TOKEN"]:
            add("deSEC API token", password=values["DESEC_TOKEN"], url="https://desec.io/")
        if "uptime-kuma" in values["BASM_MODULES"].split():
            add("Uptime Kuma administrator", url=f'http://{values["MANAGEMENT_BIND_ADDRESS"]}:{values["UPTIME_KUMA_PORT"]}', notes="Private listener; use an SSH tunnel for loopback access from another computer. Record the account created during first-time setup here. BASM cannot discover its password.")
        for title in ("Server administrator", "Router administrator", "Domain provider", "Internet provider", "Off-site backups"):
            add(title, notes="Ask IT to record the existing account here; BASM does not know these credentials.")
        attachments = []
        for directory in (root / "modules" / "wireguard", config / "prepared-modules" / "wireguard"):
            attachments.extend((f"WireGuard {name}", directory / name) for name in ("config.conf", "peer1.conf"))
        for title, path in attachments:
            if path.is_file() and vault.find_entries(title=title, group=group, first=True) is None:
                entry = add(title, notes="Private key material is attached to this entry.")
                binary = vault.add_binary(path.read_bytes())
                entry.add_attachment(binary, path.name)
        vault.save(temporary)
        os.chmod(temporary, 0o600)
        if owner is not None and (temporary.stat().st_uid, temporary.stat().st_gid) != (owner.st_uid, owner.st_gid):
            os.chown(temporary, owner.st_uid, owner.st_gid)
        if lock_file.exists() or (database.read_bytes() if database.exists() else None) != original:
            raise ValueError("Admin vault changed during synchronization; retry after closing KeePassXC")
        os.replace(temporary, database)
    finally:
        temporary.unlink(missing_ok=True)
    return master


if __name__ == "__main__":
    names = (
        "DEPLOYMENT_MODE", "HTTP_PORT", "HTTPS_PORT", "ERP_URL", "MAIL_URL", "CLOUD_URL",
        "ERP_ADMIN_PASSWORD", "NEXTCLOUD_ADMIN_USER", "NEXTCLOUD_ADMIN_PASSWORD", "ADMIN_EMAIL",
        "DB_ROOT_PASSWORD", "NEXTCLOUD_DB_PASSWORD", "RESTIC_PASSWORD", "BACKUP_LOCATION",
        "DESEC_TOKEN", "BASM_MODULES", "MANAGEMENT_BIND_ADDRESS", "UPTIME_KUMA_PORT",
    )
    try:
        fields = sys.stdin.buffer.read().decode().split("\0")
        if len(fields) != len(names) + 1 or fields[-1] != "":
            raise ValueError("Invalid credential input")
        print(sync(Path(sys.argv[1]), dict(zip(names, fields[:-1]))))
    except Exception:
        print("KeePass synchronization failed; check the protected database and master password files.", file=sys.stderr)
        sys.exit(1)