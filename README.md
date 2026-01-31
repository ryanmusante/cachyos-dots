# cachyos-dots

CachyOS dotfiles for Beelink GTR9 Pro (AMD Ryzen AI Max+ 395 / Strix Halo).

Performance-optimized configuration for a single-user gaming desktop that stays on 24/7. These configs prioritize maximum performance over power savings and mask sleep/suspend targets.

> **Note:** For complete implementation details, safety notes, design decisions, and troubleshooting, see the extensive comments in `ry-install.fish` and individual config files.

## Quick Start

```fish
git clone https://github.com/ryanmusante/cachyos-dots.git
cd cachyos-dots
./ry-install.fish              # Interactive installation
```

**Prerequisites:**
- CachyOS with systemd-boot (vanilla Arch with modifications may work)
- Fish shell installed
- System fully updated (`sudo pacman -Syu`)
- Internet connection for package installation

## Installer Options

| Flag | Description |
|------|-------------|
| `--all` | Unattended mode (auto-yes to all prompts) |
| `--dry-run` | Preview changes without modifying system |
| `--diff` | Compare repository files against installed system |
| `--verify` | Full verification (static + runtime) |
| `--verify-static` | Config file existence and content checks |
| `--verify-runtime` | Live system state (run after reboot) |
| `--lint` | Fish syntax and anti-pattern checks |
| `-h`, `--help` | Display help message |
| `-v`, `--version` | Display version |

**Examples:**
```fish
./ry-install.fish --dry-run    # Preview all changes first
./ry-install.fish --all        # Unattended installation
./ry-install.fish --diff       # See what differs from system
./ry-install.fish --verify     # Full post-install verification
```

## Safety Notes

| Issue | Details |
|-------|---------|
| **Systemd timeouts** | Uses 30s start, 15s stop/abort. The commonly-used 5s timeout causes flaky boots on fresh installs where services need more time (filesystem checks, cache builds, network config). |
| **AMDGPU udev timing** | The udev rule may fail silently on boot because the sysfs attribute doesn't exist when the rule triggers (Arch bug #72655). The `amdgpu-performance.service` fallback is strongly recommended. |
| **mt7925e.disable_aspm** | MediaTek WiFi 7 specific parameter. Harmless but unnecessary on other hardware. Verification auto-skipped if driver not present. |
| **WiFi backend transition** | When switching from wpa_supplicant to iwd, complete all installation steps in one session. The backend switch may disconnect WiFi. |
| **Reboot required** | Kernel command line, initramfs changes, and module blacklists only take effect after reboot. |
| **Backup created** | Installer backs up existing files to `~/.backup`. Manual restore required if issues occur. |
| **Log accumulation** | Log files (`~/cachyos-dots-*.log`) accumulate. Clean periodically with `rm ~/cachyos-dots-*.log`. |

## ⚠️ Laptop Users

These configs prioritize performance over battery life. Modify the following for laptops:

| Setting | File | Current | Change to |
|---------|------|---------|-----------|
| NVMe power saving | sdboot-manage.conf | `nvme_core.default_ps_max_latency_us=0` | Remove parameter |
| USB autosuspend | sdboot-manage.conf | `usbcore.autosuspend=-1` | Remove parameter |
| Bluetooth autosuspend | sdboot-manage.conf | `btusb.enable_autosuspend=n` | Remove parameter |
| Zswap | sdboot-manage.conf | `zswap.enabled=0` | Remove if <16GB RAM |
| GPU power management | 99-cachyos-udev.rules | `power_dpm_force_performance_level=high` | Change to `auto` |
| WiFi power saving | 99-cachyos-nm.conf | `wifi.powersave=2` (disabled) | Change to `3` (enabled) |
| iwd power saving | main.conf | `PowerSaveDisable=*` | Remove or set to specific drivers |
| Sleep targets | Manual | Masked | Unmask: `sudo systemctl unmask sleep.target suspend.target` |

## ⚠️ Security Tradeoffs

| Parameter | Risk | Mitigation |
|-----------|------|------------|
| `split_lock_detect=off` | Creates DoS vulnerability where malicious software can degrade system performance via split lock abuse. | Only acceptable on single-user gaming desktops. Remove on multi-user or server systems. Installer shows warning and requires confirmation. |
| `tsc=reliable` | May cause timing issues on systems without `constant_tsc` CPU flag. | Verify support first: `grep constant_tsc /proc/cpuinfo`. Safer alternative: `tsc=nowatchdog`. |
| `loader.conf editor=no` | Prevents boot-time parameter editing but doesn't stop live USB attacks. | For full boot security: enable UEFI Secure Boot, set BIOS password, use LUKS encryption, configure TPM-based unlock. |
| `audit=0` | Disables kernel audit subsystem. | Acceptable on single-user desktops. Re-enable for systems requiring security auditing. |

## Implementation Notes

### Critical Behaviors

| Feature | Behavior |
|---------|----------|
| **LUKS Encryption** | `sd-encrypt` hook NOT included by default. Installer detects LUKS (via `lsblk` and `/etc/crypttab`) and offers to add it automatically. Without this hook on encrypted systems: **system will not boot**. |
| **Hibernation** | `resume` hook intentionally omitted because sleep targets are masked. To enable hibernation: unmask targets, add `resume` hook after `filesystems` in mkinitcpio.conf, rebuild initramfs. |
| **yay Package** | Available in CachyOS repositories only (not vanilla Arch). Installer detects CachyOS and includes yay; on vanilla Arch, use `paru` for AUR access. |
| **LVM Detection** | Installer runs `sudo pvs` before masking lvm2 services. If LVM is detected, lvm2 services are skipped to prevent breaking LVM functionality. |
| **iwd Requirement** | iwd is preinstalled on CachyOS. Required for 99-cachyos-nm.conf and main.conf to work. **Do NOT enable `iwd.service`** separately—NetworkManager manages iwd internally when configured as the backend. |
| **fstab Modification** | Installer detects btrfs subvolumes, bind mounts, and complex mount configurations. If detected, automatic fstab modification is skipped to prevent corruption. Manual editing instructions provided. |
| **COSMIC Desktop** | COSMIC-specific configuration only applied if `cosmic-comp` command exists or `/usr/share/cosmic` directory is present. |
| **ananicy-cpp** | Masked because it conflicts with manual CPU/GPU performance tuning. The automatic process prioritization can interfere with explicit performance settings. |
| **Bluetooth** | Masked by default (unused on this always-on desktop). Enable manually if needed: `sudo systemctl unmask --now bluetooth.service`. |
| **cpupower-epp.service** | Required for EPP=performance. With `amd_pstate=active`, both the governor AND Energy Performance Preference must be set. This service handles both after boot. |

### Kernel Parameters

All parameters are set in `/etc/sdboot-manage.conf` LINUX_OPTIONS and applied to `/proc/cmdline` after reboot.

| Parameter | Purpose | Notes |
|-----------|---------|-------|
| `quiet` | Suppress most boot messages | Use `dmesg` to view later |
| `8250.nr_uarts=0` | Disable legacy serial port detection | Saves ~100ms boot time |
| `amd_iommu=off` | Disable IOMMU | Enable (`amd_iommu=on iommu=pt`) if using GPU passthrough |
| `amd_pstate=active` | Enable AMD P-State EPP driver | Required for EPP control |
| `amdgpu.cwsr_enable=0` | Disable Compute Wave Save/Restore | Stability fix for some workloads |
| `amdgpu.gpu_recovery=1` | Enable GPU reset on hang | Allows recovery without reboot |
| `amdgpu.modeset=1` | Enable kernel mode setting | Required for display |
| `amdgpu.ppfeaturemask=0xfffd7fff` | PowerPlay feature mask | Enables most features safely |
| `amdgpu.runpm=0` | Disable runtime power management | Always-on desktop |
| `audit=0` | Disable kernel audit | Reduces overhead on desktop |
| `btusb.enable_autosuspend=n` | Disable Bluetooth USB autosuspend | Prevents connection drops |
| `mt7925e.disable_aspm=1` | Disable PCIe ASPM for MediaTek WiFi 7 | Hardware-specific; harmless if driver absent |
| `nmi_watchdog=0` | Disable NMI watchdog | Complements `nowatchdog` |
| `nowatchdog` | Disable hardware watchdog timers | Prevents unnecessary log messages |
| `nvme_core.default_ps_max_latency_us=0` | Disable NVMe power saving | Lower latency, higher idle power |
| `pci=pcie_bus_perf` | Optimize PCIe MPS and MRRS | Up to 10-15% improvement in NVMe speeds |
| `split_lock_detect=off` | Disable split lock detection | Gaming performance; security tradeoff |
| `tsc=reliable` | Mark TSC as reliable | Safe with `constant_tsc` flag |
| `usbcore.autosuspend=-1` | Disable USB autosuspend | Prevents peripheral issues |
| `zswap.enabled=0` | Disable zswap | Unnecessary with 128GB RAM |

### Environment Variables

Set in `/etc/environment`, applied to all sessions via PAM.

| Variable | Value | Purpose |
|----------|-------|---------|
| `AMD_VULKAN_ICD` | `RADV` | Use Mesa's RADV Vulkan driver (recommended for gaming) |
| `RADV_PERFTEST` | `sam` | Enable Smart Access Memory / ReBAR |
| `MESA_SHADER_CACHE_MAX_SIZE` | `12G` | Large shader cache reduces compilation stutters |
| `PROTON_USE_NTSYNC` | `1` | Use kernel ntsync for better game performance (kernel 6.13+) |
| `PROTON_NO_WM_DECORATION` | `1` | Disable window decorations in windowed mode |

### Other Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Timeouts 30s/15s** | Safer for first-boot scenarios. Individual services can override with `TimeoutStartSec=` in their unit files. |
| **sp5100_tco blacklist** | AMD-specific watchdog. Intel systems should blacklist `iTCO_wdt` instead. |
| **eval in _run()** | Required for command string parsing. All inputs are controlled by the script; user-provided values (WiFi credentials) are escaped before use. |
| **LINUX_OPTIONS single line** | sdboot-manage requires kernel parameters on a single line in the config file. |
| **Regulatory domain defaults US** | Installer prompts for country code. Common codes: US, GB, DE, FR, JP, AU, CA, CN. |
| **Microcode after autodetect** | Only includes microcode for current CPU (smaller image). Move before `autodetect` for portable/multi-system images. |
| **No automatic rollback** | Backup created at `~/.backup`. Manual restore required if issues occur. |
| **KERNEL=="card[0-9]"** | Udev rule matches card0-9 only. Systems with 10+ GPUs would need `card[0-9]*` pattern. |
| **PowerSaveDisable=\*** | Disables power saving for all WiFi drivers. Change to specific driver list if power savings needed on some interfaces. |
| **99-cachyos-nm.conf level=ERR** | Reduces NetworkManager log verbosity. Change to `WARN` or `DEBUG` when troubleshooting WiFi issues. |
| **Journal size** | Journal usage shown in verification is runtime observation. Configure limits in `/etc/systemd/journald.conf.d/` if needed. |
| **Duplicate module params** | Parameters for amdgpu, mt7925e, btusb, usbcore, and nvme_core are set in both `99-cachyos-modprobe.conf` (modprobe) and kernel cmdline (sdboot-manage.conf). Cmdline takes precedence for built-in modules; modprobe.d applies to loadable modules and serves as fallback. |
| **Service scripts use /bin/bash** | Hardcoded path is correct on Arch/CachyOS (symlinked to `/usr/bin/bash`). Uses bash for `shopt -s nullglob` glob support. |

## Packages

### Installed

| Package | Purpose |
|---------|---------|
| libcamera | Camera/webcam support |
| mkinitcpio-firmware | Additional firmware to suppress initramfs warnings |
| nvme-cli | NVMe drive management tools |
| htop | Interactive process viewer |
| xorg-xrdb | X11/XWayland resource database (compatibility) |
| pkgfile | Command-not-found functionality |
| plocate | Fast file search (locate command) |
| cachyos-gaming-meta | Gaming stack metapackage |
| cachyos-gaming-applications | Gaming applications |
| yay | AUR helper (CachyOS only) |

**Note:** iwd, cpupower, smartmontools, and unzip are preinstalled on CachyOS.

### Removed

| Package | Reason |
|---------|--------|
| power-profiles-daemon | Conflicts with manual CPU governor management |
| plymouth | Boot splash; unnecessary, slows boot |
| cachyos-plymouth-bootanimation | Plymouth theme |
| ufw | Firewall; use nftables directly if needed |
| ananicy-cpp | Process scheduler; conflicts with manual tuning |

### Services Masked

| Service/Target | Reason |
|----------------|--------|
| ananicy-cpp.service | Conflicts with manual performance tuning |
| bluetooth.service | Unused on this desktop; unmask if needed |
| lvm2-monitor.service | Skipped if LVM detected; unnecessary without LVM |
| ModemManager.service | Mobile broadband modems; unused on desktop |
| NetworkManager-wait-online.service | Delays boot waiting for network |
| sleep.target | Always-on desktop |
| suspend.target | Always-on desktop |
| hibernate.target | Requires resume hook if enabled |
| hybrid-sleep.target | Always-on desktop |
| suspend-then-hibernate.target | Always-on desktop |

### Services Enabled

| Service | Scope | Purpose |
|---------|-------|---------|
| amdgpu-performance.service | System | Fallback for udev timing issue |
| cpupower-epp.service | System | Sets governor and EPP to performance |
| fstrim.timer | System | Weekly SSD TRIM |
| ssh-agent.service | User | SSH key agent with socket activation |

## Files

| File | Destination | Purpose |
|------|-------------|---------|
| loader.conf | /boot/loader/ | systemd-boot: @saved default, no timeout, editor disabled |
| sdboot-manage.conf | /etc/ | Kernel command line parameters |
| mkinitcpio.conf | /etc/ | Initramfs: amdgpu/nvme modules, systemd hooks, zstd compression |
| environment | /etc/ | Global environment: Vulkan, Mesa, Proton variables |
| 99-cachyos-udev.rules | /etc/udev/rules.d/ | GPU power_dpm_force_performance_level=high |
| 99-cachyos-udev.rules | /etc/udev/rules.d/ | ntsync device permissions (MODE=0666) |
| amdgpu-performance.service | /etc/systemd/system/ | Fallback for udev timing issue |
| cpupower-epp.service | /etc/systemd/system/ | Set governor and EPP to performance |
| 99-cachyos-modprobe.conf | /etc/modprobe.d/ | AMDGPU module: modeset=1, cwsr_enable=0, gpu_recovery=1, runpm=0 |
| 99-cachyos-modprobe.conf | /etc/modprobe.d/ | Blacklist sp5100_tco watchdog |
| 99-cachyos-modprobe.conf | /etc/modprobe.d/ | MediaTek WiFi 7: disable_aspm=1 |
| 99-cachyos-modprobe.conf | /etc/modprobe.d/ | USB/Bluetooth autosuspend (DUAL with cmdline) |
| 99-cachyos-modprobe.conf | /etc/modprobe.d/ | NVMe APST disabled (DUAL with cmdline) |
| 99-cachyos-modules.conf | /etc/modules-load.d/ | Load ntsync module at boot |
| main.conf | /etc/iwd/ | iwd: NetworkConfiguration=false, PowerSaveDisable=* |
| 99-cachyos-nm.conf | /etc/NetworkManager/conf.d/ | NM: wifi.backend=iwd, wifi.powersave=2 |
| 99-cachyos-nm.conf | /etc/NetworkManager/conf.d/ | NM: logging level=ERR |
| wireless-regdom | /etc/conf.d/ | Wireless regulatory domain (default: US) |
| 99-cachyos-resolved.conf | /etc/systemd/resolved.conf.d/ | Disable mDNS to prevent avahi conflict |
| 99-cachyos-system.conf | /etc/systemd/system.conf.d/ | System timeouts: 30s start, 15s stop/abort |
| 99-cachyos-user.conf | /etc/systemd/user.conf.d/ | User timeouts: 30s start, 15s stop/abort |
| 10-ssh-auth-sock.conf | ~/.config/environment.d/ | SSH_AUTH_SOCK for systemd user sessions |
| 10-ssh-auth-sock.fish | ~/.config/fish/conf.d/ | SSH_AUTH_SOCK for fish shell |

## Backup & Restore

The installer automatically backs up existing files to `~/.backup` before overwriting.

### Manual Backup

```fish
set -l backup_dir ~/.backup
mkdir -p $backup_dir/{boot/loader,etc/{udev/rules.d,modprobe.d,modules-load.d,iwd,systemd/{system,resolved.conf.d,system.conf.d,user.conf.d},NetworkManager/conf.d,conf.d},home/.config/{environment.d,fish/conf.d}}

# System files
for f in /boot/loader/loader.conf \
         /etc/udev/rules.d/99-cachyos-udev.rules \
         /etc/modprobe.d/99-cachyos-modprobe.conf \
         /etc/modules-load.d/99-cachyos-modules.conf \
         /etc/environment \
         /etc/iwd/main.conf \
         /etc/mkinitcpio.conf \
         /etc/sdboot-manage.conf \
         /etc/systemd/system.conf.d/99-cachyos-system.conf \
         /etc/systemd/user.conf.d/99-cachyos-user.conf \
         /etc/systemd/resolved.conf.d/99-cachyos-resolved.conf \
         /etc/NetworkManager/conf.d/99-cachyos-nm.conf \
         /etc/conf.d/wireless-regdom \
         /etc/systemd/system/{amdgpu-performance,cpupower-epp}.service
    test -f $f; and sudo cp $f $backup_dir$f 2>/dev/null
end

# User files
for f in ~/.config/environment.d/10-ssh-auth-sock.conf \
         ~/.config/fish/conf.d/10-ssh-auth-sock.fish
    test -f $f; and cp $f $backup_dir/home/(string replace $HOME '' $f) 2>/dev/null
end
```

### Restore

```fish
# Restore all backed up files
sudo cp -r ~/.backup/boot/* /boot/
sudo cp -r ~/.backup/etc/* /etc/
cp -r ~/.backup/home/.config/* ~/.config/

# Rebuild initramfs and bootloader
sudo mkinitcpio -P
sudo sdboot-manage gen
sudo sdboot-manage update

# Reload systemd
sudo systemctl daemon-reload
systemctl --user daemon-reload
```

## Manual Installation

> **Warning:** WiFi users: complete all steps in one session. The backend switch may disconnect WiFi. Do NOT enable `iwd.service` separately.

```fish
# 1. Create directories
sudo mkdir -p /boot/loader \
    /etc/{iwd,NetworkManager/conf.d,udev/rules.d,modprobe.d,modules-load.d,conf.d} \
    /etc/systemd/{system,resolved.conf.d,system.conf.d,user.conf.d}
mkdir -p ~/.config/{environment.d,fish/conf.d}

# 2. Install packages (yay: CachyOS only; iwd, cpupower, smartmontools, unzip preinstalled)
sudo pacman -S --needed libcamera mkinitcpio-firmware nvme-cli htop xorg-xrdb \
    pkgfile plocate cachyos-gaming-meta cachyos-gaming-applications

# 3. Update search databases
sudo updatedb                    # plocate database for locate command
sudo pkgfile --update            # pkgfile database for command-not-found

# 4. Rank mirrors (optional but recommended)
sudo cachyos-rate-mirrors        # or: rate-mirrors --allow-resolve --protocol https arch | sudo tee /etc/pacman.d/mirrorlist

# 5. Copy configuration files
sudo cp loader.conf /boot/loader/
sudo cp 99-cachyos-udev.rules /etc/udev/rules.d/
sudo cp amdgpu-performance.service cpupower-epp.service /etc/systemd/system/
sudo cp 99-cachyos-modprobe.conf /etc/modprobe.d/
sudo cp 99-cachyos-modules.conf /etc/modules-load.d/
sudo cp environment mkinitcpio.conf sdboot-manage.conf /etc/
sudo cp main.conf /etc/iwd/
sudo cp 99-cachyos-resolved.conf /etc/systemd/resolved.conf.d/
sudo cp 99-cachyos-system.conf /etc/systemd/system.conf.d/
sudo cp 99-cachyos-user.conf /etc/systemd/user.conf.d/
sudo cp 99-cachyos-nm.conf /etc/NetworkManager/conf.d/
sudo cp wireless-regdom /etc/conf.d/
cp 10-ssh-auth-sock.conf ~/.config/environment.d/
cp 10-ssh-auth-sock.fish ~/.config/fish/conf.d/

# 6. LUKS only: add sd-encrypt before filesystems in /etc/mkinitcpio.conf
# sudo sed -i 's/\(block\) \(filesystems\)/\1 sd-encrypt \2/' /etc/mkinitcpio.conf

# 7. fstab optimization (skip on btrfs with subvolumes - check first!)
if grep -qE 'subvol=|compress=' /etc/fstab
    echo "SKIP: btrfs detected"
else
    sudo cp /etc/fstab /etc/fstab.bak
    sudo sed -i -E \
        -e 's/^(\S+\s+\/boot\s+\S+\s+)\S+/\1defaults,umask=0077/' \
        -e 's/^(\S+\s+\/\s+\S+\s+)\S+/\1defaults,noatime,lazytime,commit=60/' \
        -e 's/^(\S+\s+\/tmp\s+\S+\s+)\S+/\1defaults,noatime,lazytime,mode=1777/' \
        /etc/fstab
end

# 8. Remove conflicting packages
for pkg in power-profiles-daemon plymouth cachyos-plymouth-bootanimation ufw ananicy-cpp
    pacman -Qi $pkg >/dev/null 2>&1; and sudo pacman -Rns --noconfirm $pkg
end

# 9. Mask services (skip lvm2-monitor if using LVM - check with: sudo pvs)
sudo systemctl mask \
    ananicy-cpp.service \
    bluetooth.service \
    lvm2-monitor.service \
    ModemManager.service \
    NetworkManager-wait-online.service \
    sleep.target \
    suspend.target \
    hibernate.target \
    hybrid-sleep.target \
    suspend-then-hibernate.target

# 10. Create session directories (prevents display manager warnings)
sudo mkdir -p /usr/share/xsessions /usr/local/share/{wayland-sessions,xsessions}

# 11. Reload and enable services
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo sysctl --system
sudo systemctl daemon-reload
sudo systemctl restart NetworkManager
sudo systemctl enable --now amdgpu-performance.service cpupower-epp.service fstrim.timer
systemctl --user daemon-reload
systemctl --user enable --now ssh-agent.service

# 12. Rebuild initramfs and bootloader
sudo mkinitcpio -P
sudo sdboot-manage gen
sudo sdboot-manage update

# 13. Clear package cache (optional)
sudo pacman -Sc --noconfirm

# 14. WiFi reconnection (LAST - may disconnect)
set -l wlan (iwctl device list 2>/dev/null | awk '/station/{print $2;exit}')
test -z "$wlan"; and set wlan (ip -o link show | awk -F': ' '/wl[a-z0-9]+/{print $2;exit}')
test -z "$wlan"; and echo "No WiFi interface found"; and exit 1

read -P "WiFi SSID: " ssid
read -sP "WiFi passphrase: " pass; echo

# Escape special characters
set -l e_ssid (string replace -a '\\' '\\\\' -- "$ssid" | string replace -a "'" "'\\''" | string replace -a '$' '\\$')
set -l e_pass (string replace -a '\\' '\\\\' -- "$pass" | string replace -a "'" "'\\''" | string replace -a '$' '\\$')

iwctl --passphrase "$e_pass" station $wlan connect "$e_ssid"
```

## COSMIC Desktop

Applied only if COSMIC is installed (disables auto-suspend on AC power):

```fish
# Check if COSMIC is installed
if not command -q cosmic-comp; and not test -d /usr/share/cosmic
    echo "COSMIC not detected"
    exit 0
end

# Disable suspend on AC power
set -l base ~/.config/cosmic
mkdir -p $base/com.system76.CosmicIdle/v1
echo 'None' > $base/com.system76.CosmicIdle/v1/suspend_on_ac_time
```

## Troubleshooting

### GPU shows `auto` instead of `high`

This is Arch bug #72655—the udev rule fails silently because the sysfs attribute doesn't exist when udev processes the add event.

```fish
# Enable the fallback service
sudo systemctl enable --now amdgpu-performance.service

# Verify
cat /sys/class/drm/card*/device/power_dpm_force_performance_level
# Should show: high
```

### iwd backend not working

```fish
# Manually connect via iwd
iwctl --passphrase "YOUR_PASSPHRASE" station wlan0 connect "YOUR_SSID"

# Restart NetworkManager
sudo systemctl restart NetworkManager

# Check logs
journalctl -u NetworkManager -b | grep -iE 'backend|iwd|wifi'

# Verify iwd is being used
nmcli device wifi list  # Should work if iwd backend is active
```

### WiFi debugging

```fish
# Temporarily increase logging
sudo sed -i 's/level=ERR/level=DEBUG/' /etc/NetworkManager/conf.d/99-cachyos-nm.conf
sudo systemctl restart NetworkManager

# Reproduce issue, then check logs
journalctl -u NetworkManager -b --since "5 minutes ago"

# Restore error-only logging
sudo sed -i 's/level=DEBUG/level=ERR/' /etc/NetworkManager/conf.d/99-cachyos-nm.conf
sudo systemctl restart NetworkManager
```

### mt7925e parameter not needed

If you don't have MediaTek WiFi 7 hardware:

```fish
# Check if driver is loaded
lsmod | grep mt7925

# If empty, the parameter is unnecessary (but harmless)
# Optionally remove from sdboot-manage.conf
```

### Service timeout on boot

```fish
# Check which service timed out
journalctl -b -p err | grep -i timeout

# Increase timeout for specific service
sudo systemctl edit SERVICE_NAME
# Add:
# [Service]
# TimeoutStartSec=60s
```

### Governor/EPP not set to performance

```fish
# Check current state
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference

# Verify cpupower-epp.service is running
systemctl status cpupower-epp.service

# Manually set (temporary)
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
```

### ntsync not available

```fish
# Check kernel version (requires 6.13+)
uname -r

# Check if module exists
modinfo ntsync

# Check kernel config
zgrep CONFIG_NTSYNC /proc/config.gz

# Try loading manually
sudo modprobe ntsync

# Verify device
ls -la /dev/ntsync
```

## Verification

Run `./ry-install.fish --verify` for comprehensive checks, or `--verify-static` for config-only and `--verify-runtime` for live system state.

### Static Verification (Config Files)

| Category | Check | Expected |
|----------|-------|----------|
| **mkinitcpio.conf** | MODULES | amdgpu, nvme |
| | HOOKS | base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck |
| | COMPRESSION | zstd |
| **loader.conf** | default | @saved |
| | timeout | 0 |
| | console-mode | keep |
| | editor | no |
| **sdboot-manage.conf** | LINUX_OPTIONS | All kernel parameters present |
| | tsc=reliable safety | constant_tsc CPU flag present |
| **99-cachyos-udev.rules** | power_dpm rule | Present |
| | ACTION match | add |
| | SUBSYSTEM match | drm |
| | DRIVERS match | amdgpu |
| **99-cachyos-udev.rules** | KERNEL match | ntsync |
| | MODE | 0666 |
| **99-cachyos-modules.conf** | Module entry | ntsync |
| **amdgpu-performance.service** | ExecStart | power_dpm_force_performance_level |
| | After | graphical.target |
| | ConditionPathIsDirectory | /sys/class/drm |
| | WantedBy | graphical.target |
| **cpupower-epp.service** | ExecStart | energy_performance_preference, scaling_governor |
| | After | cpupower.service |
| | Wants | cpupower.service |
| | WantedBy | multi-user.target |
| | Type | oneshot |
| | RemainAfterExit | yes |
| **environment** | AMD_VULKAN_ICD | RADV |
| | RADV_PERFTEST | sam |
| | MESA_SHADER_CACHE_MAX_SIZE | 12G |
| | PROTON_USE_NTSYNC | 1 |
| | PROTON_NO_WM_DECORATION | 1 |
| **99-cachyos-modprobe.conf** | sp5100_tco | Blacklisted and install disabled |
| **99-cachyos-modprobe.conf** | amdgpu options | modeset=1, cwsr_enable=0, gpu_recovery=1, runpm=0 |
| **99-cachyos-modprobe.conf** | mt7925e disable_aspm | 1 (skipped if driver not present) |
| **99-cachyos-modprobe.conf** | btusb enable_autosuspend | n |
| **99-cachyos-modprobe.conf** | usbcore autosuspend | -1 |
| **99-cachyos-modprobe.conf** | nvme_core default_ps_max_latency_us | 0 |
| **main.conf** | [General] | EnableNetworkConfiguration=false |
| | [DriverQuirks] | DefaultInterface=*, PowerSaveDisable=* |
| | [Network] | NameResolvingService=systemd |
| **99-cachyos-nm.conf** | wifi.backend | iwd |
| | wifi.powersave | 2 (disabled) |
| **99-cachyos-nm.conf** | level | ERR |
| **wireless-regdom** | WIRELESS_REGDOM | Set (default: US) |
| **99-cachyos-resolved.conf** | MulticastDNS | no |
| **99-cachyos-system.conf** | DefaultTimeoutStartSec | 30s |
| | DefaultTimeoutStopSec | 15s |
| | DefaultTimeoutAbortSec | 15s |
| **99-cachyos-user.conf** | Same as 99-cachyos-system.conf | 30s/15s/15s |
| **SSH agent (user)** | SSH_AUTH_SOCK | XDG_RUNTIME_DIR/ssh-agent.socket |
| **Masked services** | All listed | masked |
| **Enabled services** | fstrim.timer, cpupower-epp.service | enabled |
| | ssh-agent.service (user) | enabled or indirect |
| **Packages installed** | All PKGS_ADD | Installed |
| **Packages removed** | All PKGS_DEL | Not installed |

### Runtime Verification (Live System)

| Category | Check | Expected |
|----------|-------|----------|
| **CPU** | Microcode | Loaded |
| | constant_tsc | Present (required for tsc=reliable) |
| | Scaling driver | amd-pstate-epp |
| | Governor | performance |
| | EPP | performance |
| **Boot** | Initramfs compression | ZSTD |
| | Kernel cmdline | All parameters present |
| **GPU** | power_dpm_force_performance_level | high |
| | SAM/ReBAR | Enabled (if BIOS supports) |
| **Modules** | sp5100_tco | Not loaded |
| | ntsync | Loaded (kernel 6.13+) |
| **Services** | cpupower-epp.service | active or exited |
| | fstrim.timer | active |
| | amdgpu-performance.service | active (if installed) |
| | ssh-agent socket | Exists at $XDG_RUNTIME_DIR/ssh-agent.socket |
| **Environment** | All ENV_VARS | Set correctly |
| **ntsync** | /dev/ntsync | Exists (kernel 6.13+) |
| **WiFi** | Interface | Detected |
| | iwd process | Running |
| | Regulatory domain | Matches wireless-regdom |
| **Systemd** | DefaultTimeoutStartUSec | 30s |
| | DefaultTimeoutStopUSec | 15s |
| | DefaultTimeoutAbortUSec | 15s |
| | Journal usage | Reported (no configured limit) |

### Quick Runtime Check

```fish
# GPU performance level
cat /sys/class/drm/card*/device/power_dpm_force_performance_level
# Expected: high

# CPU governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
# Expected: performance

# CPU EPP
cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference
# Expected: performance

# Kernel parameters
cat /proc/cmdline | tr ' ' '\n' | grep -E 'amd_pstate|amdgpu|split_lock|tsc'
# Expected: all present

# Services
systemctl is-active cpupower-epp.service fstrim.timer
# Expected: active (or exited for cpupower-epp)

# ntsync (kernel 6.13+)
test -c /dev/ntsync; and echo "ntsync: OK"; or echo "ntsync: not available"
lsmod | grep ntsync

# constant_tsc (required for tsc=reliable)
grep -q constant_tsc /proc/cpuinfo; and echo "constant_tsc: OK"; or echo "constant_tsc: MISSING"

# Environment variables
printenv | grep -E 'AMD_VULKAN|RADV_PERFTEST|MESA_SHADER|PROTON'
```

## License

MIT

## File Format

All files maintain POSIX compliance (trailing newline at EOF). Blank lines within code blocks use intentional whitespace for readability—do not strip trailing whitespace from these lines.
