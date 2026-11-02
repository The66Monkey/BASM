# KeePass: Admin, Team and Personal Vaults

## Separate the audiences

| Vault | Who can open it | Purpose |
| --- | --- | --- |
| BASM admin | Owner/IT only | Service administrators, database/recovery secrets |
| Team | Explicitly authorized employees | Only intentionally shared credentials |
| Personal | Individual employee | Their own accounts; never the admin vault |

Use different master passwords. Everyone who can decrypt a shared KDBX can read
all its entries and retain a copy. KeePass does not provide per-entry employee
permissions, central auditing or revocation of previously copied secrets.

## Admin share: current home-lab deployment

The canonical database is `/opt/basm/vaults/admin/credentials.kdbx` on the BASM
VM (`192.168.50.20`). The private Samba share is `BASM-Admin`; its dedicated
login is `basm-vault`. This is a manually configured deployment addition, not
an automatically provisioned BASM module.

On the VM, retrieve the share password privately:

```sh
sudo cat /opt/basm/config/admin-vault-smb-password
```

The share password authenticates SMB. The separate KDBX master password
decrypts the database; retrieve it from the private owner handover:

```sh
sudo less /opt/basm/handover/for-the-user.txt
```

### Open from a workstation

1. Install KeePassXC on the workstation.
2. On the LAN or VPN, open your file manager's **Connect to Server** feature:
   `smb://192.168.50.20/BASM-Admin`. On Windows use
   `\\192.168.50.20\BASM-Admin`.
3. Log in as `basm-vault` using the share password.
4. Open `credentials.kdbx` from that share in KeePassXC, using the vault master
   password. If KeePassXC cannot open your file manager's virtual SMB location,
   mount the share through your OS first and open its mounted filesystem path.
   Do not solve this by downloading another editable copy.
5. Add a harmless test entry, save, close, reopen from the share and confirm it
   persisted. Then remove the test entry. Verify this before relying on sharing.

The owner confirmed workstation access works in the current deployment.
This does not replace recovery or concurrent-edit testing.

Retire the earlier downloaded copy from everyday use after reconciling any
edits; do not overwrite the canonical server file with an older download.
Encrypted, dated recovery copies are still necessary and are not working vaults.

Save and close before disconnecting. A network outage can prevent saves.
Workstation memory, caches or saved copies may still contain vault data; this
is a canonical-file workflow, not a guarantee of server-only data.

### Access boundaries and maintenance

- SMB3 encryption/signing and an authenticated, non-guest login are required.
- TCP 445 is bound to the VM's LAN interface, with LAN/VPN source restrictions.
  Never forward it publicly. NetBIOS discovery is disabled.
- Only the dedicated vault directory is shared. The saved master password,
  runtime environment, handovers and other BASM config are outside it.
- The dedicated system account has no shell login. The database is mode `0600`
  owned by that account; parent traversal uses a specific POSIX ACL.
- Close the vault before BASM synchronization, installer reruns or handover
  regeneration. BASM preserves existing entries and file ownership, refuses a
  recognized lock file, and checks for concurrent changes before replacing it.
  These checks do not eliminate every network/concurrent-edit race: coordinate
  writers and review conflicts in KeePassXC rather than overwriting silently.
- Changing an application's password does not change it in KeePass, or vice
  versa. Correct imported accounts manually. A vault master-password change
  also requires updating the root-only `config/keepass-master-password`.

The KDBX is inside BASM's backup tree. The share's host configuration is not:
protect a recovery copy of `/etc/samba/smb.conf`, Samba's account state and
the POSIX access setup separately. Replacement-host recovery must recreate the
dedicated user, its Samba login and traversal ACLs before reopening the share.
This deployment stores a protected export in `config/admin-share-recovery/`
(configuration, account identifiers, Samba password hash and ACLs) so subsequent
BASM snapshots include it. Refresh that export after changing share accounts or
permissions; it is not maintained automatically. Treat the export as a secret.
Keep an independent copy of the KDBX master password; don't store the sole
Restic decryption key inside the repository encrypted by that key.

## Team vault (planned, not provisioned)

Create a separate empty KDBX containing only shared employee credentials, with
its own master password. Use a separate restricted share and individual SMB
accounts so access can be managed without exposing the admin share.
Coordinate writes, reload/merge when prompted, and test conflict behavior.
Removing share access cannot revoke previously copied secrets; rotate affected
credentials when someone leaves.

Do not copy the admin vault as the starting point: deleted entries/history can
retain secrets. Do not share BASM's administrator account or the `basm-vault`
login with employees.

## Personal vaults in Nextcloud

Give each employee their own Nextcloud account and private KDBX. Do not use
the Nextcloud administrator account for ordinary employee file storage.
Nextcloud sync provides availability/version history but makes local copies;
save/close before switching devices and resolve conflicts explicitly. It is
not the same as direct shared-file access. Keep recovery material independent
of the accounts and passwords locked inside the vault.
