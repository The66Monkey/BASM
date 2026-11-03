# Production Virtual Machines and Backup Storage

BASM can run in a production Debian VM. Give the guest its own reserved network
address and enough CPU, RAM and disk for its applications; a VM is not BASM's
`local` test mode. Docker and the BASM installer run **inside the guest**.
The hypervisor, physical storage, firewall and guest lifecycle remain IT's
responsibility. Do not run the Debian installer on the hypervisor.

## Recommended storage layout

Keep application data on the guest disk and encrypted Restic backups on a
different physical backup disk. Expose **only a dedicated BASM backup directory**
to the guest, not the whole host filesystem. For example:

```text
Hypervisor external disk: /mnt/backup-disk
Dedicated host directory: /mnt/backup-disk/basm
Virtiofs share tag:        basm-backup
Guest backup mount:        /var/backups/basm
Encrypted repository:     /var/backups/basm/restic
```

These are examples, not deployment-specific values. The share tag is not a
password. Keep the actual disk UUID, VM definition and mount configuration in a
private operator record.

This layout protects against guest-disk loss and permits recovery without the
old VM. A second virtual disk on the application disk, or a hypervisor
snapshot on that disk, does not provide physical disk-failure protection.

Do not pass through a disk to the VM while its filesystem is mounted on the host.
Use a directory share, a dedicated exclusively attached disk, or an
administrator-managed storage server instead. Never mount one ordinary ext4
filesystem read/write independently in both host and guest.

## KVM/libvirt example: virtiofs

Virtiofs avoids opening a network storage service. Other hypervisors can provide
an equivalent persistent directory share or dedicated backup disk. BASM also
lists mounted NFS/NFS4 and SMB/CIFS shares; IT must configure their restricted
access, boot ordering, credentials and reliable filesystem semantics separately.
Never put network-share credentials in the BASM source repository.

### 1. Prepare the host disk and directory

Use an existing, verified backup filesystem. These steps do **not** format a disk.
Check its identity with `lsblk -f` and arrange a persistent host mount using its
UUID, not a changeable `/dev/sdX` name. For example, in the **host's** `/etc/fstab`:

```fstab
UUID=REPLACE_WITH_BACKUP_DISK_UUID /mnt/backup-disk ext4 defaults,nofail 0 2
```

After mounting, verify the expected UUID before creating the share:

```sh
sudo systemctl daemon-reload
sudo install -d -m 755 /mnt/backup-disk
sudo mount /mnt/backup-disk
findmnt --mountpoint /mnt/backup-disk -o TARGET,SOURCE,FSTYPE,UUID
df -h /mnt/backup-disk
# Continue only if this is the intended external filesystem.
sudo install -d -m 700 /mnt/backup-disk/basm
```

Do not create a fallback backup directory under an unmounted host mountpoint.
Allow enough capacity for retained history and growth, not just today's data.

### 2. Add the directory to the VM

Install the hypervisor's `virtiofsd` package if missing. Schedule a maintenance
window, gracefully shut down the guest and confirm it is **shut off**:

```sh
sudo virsh -c qemu:///system shutdown basm
sudo virsh -c qemu:///system domstate basm
```

Do not force-stop a guest merely to finish this procedure. Save a private copy
of its inactive XML before editing. Use
`sudo virsh -c qemu:///system edit basm` to add or merge this top-level element
(do not duplicate an existing `memoryBacking`):

```xml
<memoryBacking>
  <source type='memfd'/>
  <access mode='shared'/>
</memoryBacking>
```

Under the existing `<devices>` element, add:

```xml
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs' queue='1024'/>
  <source dir='/mnt/backup-disk/basm'/>
  <target dir='basm-backup'/>
</filesystem>
```

Keep SELinux/AppArmor and the hypervisor's sandbox enabled. Use its supported
directory labels and ownership if access is denied; do not use `chmod 777`,
disable confinement or expose a larger directory to work around an error.
The BASM guest is trusted with read/write access to this directory, including
deleting backups; this is not immutable storage.

### 3. Order host startup after the disk mount

Guest autostart must not export an empty host directory when the disk is absent.
On a dedicated host using modular libvirt, add the following with
`sudo systemctl edit virtqemud.service`:

```ini
[Unit]
RequiresMountsFor=/mnt/backup-disk/basm
```

For monolithic libvirt, the service is `libvirtd.service` instead. Confirm which
service the host actually uses; do not enable a second libvirt daemon.
Run `sudo systemctl daemon-reload`. This dependency affects **all VMs started
through that daemon**; on a shared hypervisor, have IT arrange an equivalent
per-VM mount prerequisite rather than unexpectedly blocking unrelated VMs.
Also retain the disk's real mount entry: a directory alone is not a mount.

Confirm the disk is mounted, then start the VM:

```sh
sudo virsh -c qemu:///system start basm
```

### 4. Mount the share persistently inside Debian

For a **new install**, create an empty mountpoint in the guest:

```sh
sudo install -d -m 700 /var/backups/basm
```

Add this to the **guest's** `/etc/fstab`:

```fstab
basm-backup /var/backups/basm virtiofs rw,nosuid,nodev,noexec,nofail,x-systemd.mount-timeout=30s 0 0
```

Then activate and inspect it:

```sh
sudo systemctl daemon-reload
sudo systemctl start var-backups-basm.mount
findmnt --mountpoint /var/backups/basm -o TARGET,SOURCE,FSTYPE,OPTIONS
```

The source must be `basm-backup`, type `virtiofs`, writable. `nofail` permits the
guest to boot for repairs when the share is unavailable; it does not permit BASM
to bypass a saved backup filesystem identity. The first install has no saved
identity yet: **verify the mount before starting the installer**.

In the wizard, keep `/var/backups/basm` if mounted as above. If you mounted the
share elsewhere, select its numbered entry (which uses a `basm-backups`
subdirectory) or enter the intended absolute directory. BASM lists writable
block-device, virtiofs, NFS/NFS4 and CIFS mounts. It does not configure the
hypervisor, mount a share, format a disk or alter access policies.

## Moving an existing VM-disk repository

Preserve the existing guest `BACKUP_LOCATION` so cron jobs, recovery settings,
Fluxer archives and handover documents keep the same paths. Do not just edit
the configuration or delete `config/backup-device` to silence a mismatch.
Use a reviewed BASM release that provides `backup-adopt-mount`; confirm it is
listed in `sudo basm help` **before** changing the storage.

1. Prepare the host share as above. Temporarily mount it at an empty guest
   staging directory, such as `/mnt/basm-backup-transfer`; do **not** mount it
   over the old repository yet.

   ```sh
   sudo install -d -m 700 /mnt/basm-backup-transfer
   sudo mount -t virtiofs -o rw,nosuid,nodev,noexec basm-backup /mnt/basm-backup-transfer
   ```

2. Before copying, acquire BASM's deployment lock and hold it through copying
   and switching mounts. For the default production deployment:

   ```sh
   sudo flock -n /opt/basm/logs/update.lock bash --noprofile --norc -e
   ```

   If the lock cannot be acquired, wait for the other operation. The following
   steps run in that root shell. Do not run another BASM command that needs the
   lock until you exit it. This shell exits on a failed command; stop and inspect
   the storage state before continuing after any failure. Schedule outside
   automatic-maintenance hours.
3. Confirm staging is the intended virtiofs mount and is empty. Copy **all**
   existing backup contents, including Restic and any Fluxer archives:

   ```sh
   findmnt --mountpoint /mnt/basm-backup-transfer -o TARGET,SOURCE,FSTYPE
   cp -a /var/backups/basm/. /mnt/basm-backup-transfer/
   chmod 700 /mnt/basm-backup-transfer /mnt/basm-backup-transfer/restic
   diff -qr /var/backups/basm /mnt/basm-backup-transfer
   sync -f /mnt/basm-backup-transfer
   ```

   Check every command succeeds; a copy/permission failure is not safe to ignore.
   The share must support ordinary files, locking and atomic renames. Do not
   copy or synchronize a repository while another Restic writer is active.
4. Unmount staging, rename the old directory to an unused holding name and
   create an empty mountpoint at the original location. Keep the original data:

   ```sh
   umount /mnt/basm-backup-transfer
   # Confirm this holding name does not already exist before moving.
   test ! -e /var/backups/basm-before-host-storage
   test ! -L /var/backups/basm-before-host-storage
   mv -T /var/backups/basm /var/backups/basm-before-host-storage
   chmod 700 /var/backups/basm-before-host-storage
   install -d -m 700 /var/backups/basm
   ```

   Add/activate the guest fstab entry from step 4 above and check `findmnt` again.
   If anything fails, stop and repair the mount or return to the preserved copy;
   do not initialize an empty repository over the problem.
5. Exit the locked shell. Run:

   ```sh
   sudo basm backup-adopt-mount
   ```

   Normal backup commands still reject the changed filesystem until this
   succeeds. Adoption takes the deployment lock, requires a mounted filesystem
   separate from the deployment, decrypts the existing repository, requires a
   complete snapshot for this deployment and reads/verifies **all** repository
   data. Only then does it atomically replace `config/backup-device`, retaining
   the previous identity in a root-only `backup-device.before-adopt.*` file.
   It does not mount, move, prune or delete any data, change credentials, or
   change the backup path. A failure leaves the saved identity unchanged.
6. Follow the acceptance checks below before removing any original copy.
   Keep the holding directory out of other scheduled repository writers.

## Acceptance and recovery

- Run `sudo basm snapshots`; confirm old snapshots remain.
- In an agreed application maintenance window, run `sudo basm backup` and
  `sudo basm check`. This backup pauses services and applies normal retention.
- Run `sudo basm verify-backup` to read/verify repository data.
- Restore an explicit snapshot to a new staging directory using
  `sudo basm restore SNAPSHOT_ID /srv/basm-restore-check` and inspect its contents.
- With no maintenance running, hold the deployment lock, unmount the guest
  share, exit the lock and confirm `sudo basm snapshots` fails with a filesystem
  error rather than creating a repository on the guest disk. Remount immediately
  and confirm normal access. Do not test by unplugging a disk during writes.
- In a scheduled window, reboot the guest and then the hypervisor; confirm mount
  ordering, backups and services recover. Plan a controlled missing-disk boot
  test too. Checking only live XML/fstab is not a reboot test.
- On a replacement VM, recreate the share at the original guest path **before**
  following [replacement-host recovery](backup.md#replacement-host).
  Full recovery intentionally records the replacement filesystem identity.

A hypervisor snapshot/export does not automatically include virtiofs contents.
Test a full isolated replacement VM with the encrypted repository and recovery
kit; file integrity checks alone do not prove application recovery.
