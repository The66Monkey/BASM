# Reinstalling or Upgrading BASM

This document covers uninstalling BASM and performing fresh installations, including troubleshooting for systems that previously hosted BASM.

## Full Uninstall

To completely remove BASM from your system:

```bash
sudo ./uninstall.sh
```

The uninstall script will:
1. Prompt you to select the deployment mode (production or local test)
2. Confirm you want to remove BASM
3. Stop all Docker containers and services
4. Remove all volumes and networks
5. Delete the BASM installation directory and all data

**Warning:** This is permanent. Backups in external locations are unaffected.

### Uninstall Verification

After running the uninstall script, verify removal:

```bash
# Check installation directory is gone
ls /opt/basm 2>/dev/null || echo "Production install removed"
ls /opt/basm-local 2>/dev/null || echo "Local install removed"

# Check Docker volumes are gone
sudo docker volume ls | grep -i basm || echo "No BASM volumes remain"
```

## Reinstalling on an Existing System

If you've previously run BASM on this system, Docker and containerd may retain configuration that conflicts with a fresh install. Follow this procedure for a clean reinstall:

### Step 1: Remove Old Installation

```bash
sudo ./uninstall.sh
```

### Step 2: Clean Docker Configuration

Previous BASM installations configure Docker with a custom data root. Reset to defaults:

```bash
# Stop Docker services
sudo systemctl stop docker containerd

# Remove custom configuration files
sudo rm /etc/docker/daemon.json 2>/dev/null || true
sudo rm /etc/containerd/config.toml 2>/dev/null || true

# Restart with default configuration
sudo systemctl start docker containerd
```

### Step 3: Clean Docker and Containerd Caches

Free up disk space by removing Docker images and containerd snapshots:

```bash
# Clean up unused images and containers (safe - removes only unused items)
sudo docker system prune -af

# Clean containerd snapshots (if previous builds failed)
sudo systemctl stop containerd
sudo rm -rf /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/*
sudo rm -rf /var/lib/containerd/io.containerd.content.v1.*
sudo systemctl start containerd
```

### Step 4: Verify Disk Space

BASM requires at least 30GB free disk space for Docker images and application data:

```bash
df -h /
# Should show at least 30GB in the "Avail" column
```

If disk space is low, consider:
- Removing old Docker images: `sudo docker image prune -a`
- Cleaning apt cache: `sudo apt clean`
- Moving Docker to a separate disk (see Docker documentation)

### Step 5: Fresh Install

Now run the installation normally:

```bash
cd /path/to/basm
sudo ./install.sh
```

## Troubleshooting Reinstalls

### "Device or Resource Busy" When Removing Old Installation

This occurs when Docker or containerd is still holding file locks:

```bash
# Force unmount the installation directory (if it's a separate volume)
sudo umount -l /opt/basm-local

# Use lsof to find what's holding files
sudo lsof /opt/basm-local 2>/dev/null | head -5

# Kill processes holding the directory (note their PIDs from lsof output)
sudo kill -9 <PID>

# Then try removal again
sudo rm -rf /opt/basm-local
```

### "No Space Left on Device" During Installation

This happens when Docker images are too large for available space. Solutions:

```bash
# Option 1: Free up space before installing
sudo docker system prune -af
sudo apt clean

# Option 2: Move Docker data to a larger disk
# Edit /etc/docker/daemon.json and set data-root to a larger filesystem
# Then restart: sudo systemctl restart docker

# Option 3: Temporarily use external storage
sudo mkdir -p /media/external/docker
sudo docker run -v /media/external/docker:/var/lib/docker ...
```

### "Containerd Snapshots" Directory Missing

If you see errors about missing `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/`, follow the "Clean Docker Configuration" step above and restart both services.

### Docker Configuration Conflicts

Check for custom Docker configuration left from previous installs:

```bash
# View current configuration
sudo cat /etc/docker/daemon.json 2>/dev/null || echo "No custom config"

# If it contains "data-root": "/opt/basm-local/docker", remove it:
sudo rm /etc/docker/daemon.json
sudo systemctl restart docker
```

Similarly for containerd:

```bash
sudo grep -A 2 "root =" /etc/containerd/config.toml
# If it shows "/opt/basm-local/containerd", reset it:
sudo rm /etc/containerd/config.toml
sudo systemctl restart containerd
```

## Upgrading to a Newer BASM Version

To upgrade an existing BASM installation without losing data:

1. **Pull the latest code:**
   ```bash
   cd /path/to/basm
   git pull origin main
   ```

2. **Backup current configuration:**
   ```bash
   sudo cp -r /opt/basm/config /opt/basm/config.backup
   ```

3. **Run the installer:**
   ```bash
   sudo ./install.sh
   ```
   The installer will detect the existing installation and update it while preserving credentials, settings, and data.

4. **Verify the upgrade:**
   ```bash
   sudo docker ps
   sudo ./update.sh  # If application images need updating
   ```

## Moving BASM to a Larger Disk

If you need more space than your current root filesystem provides:

1. **Create new installation directory on the larger disk:**
   ```bash
   sudo mkdir -p /mnt/large-disk/basm-data
   ```

2. **Uninstall the old installation:**
   ```bash
   sudo ./uninstall.sh
   ```

3. **Update the BASM installation script to use the new location:**
   ```bash
   # Set the BASM_ROOT environment variable
   export BASM_ROOT=/mnt/large-disk/basm-data
   sudo -E ./install.sh
   ```

4. **Restore backups if needed:**
   ```bash
   sudo cp /mnt/old-disk/backups/* /mnt/large-disk/basm-data/backups/
   ```

## Testing Installation Scripts

To verify the installation and uninstall scripts work correctly on a system:

```bash
# Test in a non-production environment with sufficient disk space (30GB+)

# Test uninstall
sudo ./uninstall.sh  # Answer 'local' when prompted, then 'y' to confirm

# Verify removal
ls /opt/basm-local 2>/dev/null || echo "✓ Uninstall successful"

# Test fresh install
sudo ./install.sh
# Follow wizard prompts:
# - Domain: local
# - Bind address: localhost
# - Company Name: Test Company
# - Admin Email: admin@test.local
# - Timezone: Etc/UTC
# - Nextcloud admin: basm-admin

# Verify installation
sudo docker ps | grep basm-local || echo "✓ Install successful"
cat /opt/basm-local/output/installation-summary.txt
```

## System Requirements for Installation

- **Debian 12 or Debian 13** (other Debian-based systems are not officially supported)
- **30GB free disk space** (for Docker images and full database/backup storage)
- **2GB RAM minimum** (4GB+ strongly recommended for production)
- **Internet connection** (for downloading Docker images and packages)
- **Root access** via sudo (installation must run with `sudo`)
- **CPU with virtualization support** (for optimal performance)

On systems with less than 30GB available, consider:
- Using an external volume for Docker data
- Installing on a fresh, dedicated server
- Using cloud infrastructure with sufficient resources
