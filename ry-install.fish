#!/usr/bin/env fish
#
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     CachyOS Dotfiles Installer v1.0                          ║
# ║                                                                              ║
# ║  Target: Beelink GTR9 Pro (AMD Ryzen AI Max+ 395 / Strix Halo)              ║
# ║  Author: Ryan Musante                                                        ║
# ║  License: MIT                                                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# USAGE:
#   ./ry-install.fish [OPTIONS]
#
# OPTIONS:
#   --all             Unattended installation (auto-yes to all prompts)
#   --dry-run         Preview changes without modifying system
#   --diff            Compare repository files against installed system
#   --verify          Run full verification (static + runtime)
#   --verify-static   Verify config file existence and content
#   --verify-runtime  Verify live system state (run after reboot)
#   --lint            Run fish syntax and anti-pattern checks
#   -h, --help        Display help message
#   -v, --version     Display version
#
# EXAMPLES:
#   ./ry-install.fish              # Interactive installation
#   ./ry-install.fish --dry-run    # Preview all changes
#   ./ry-install.fish --all        # Unattended installation
#   ./ry-install.fish --verify     # Full post-install verification
#
# ══════════════════════════════════════════════════════════════════════════════
# IMPLEMENTATION NOTES
# ══════════════════════════════════════════════════════════════════════════════
#
# GPU POWER MANAGEMENT:
#   • AMDGPU udev timing (Arch bug #72655): The udev rule may fail silently on
#     boot because the sysfs attribute doesn't exist when the rule triggers.
#     Solution: Enable amdgpu-performance.service as a fallback.
#
# MKINITCPIO HOOKS:
#   • resume hook: Intentionally omitted because sleep targets are masked.
#     Add 'resume' hook after 'filesystems' if enabling hibernation.
#   • sd-encrypt hook: Not included by default. Systems with LUKS encryption
#     MUST add 'sd-encrypt' hook before 'filesystems' or system won't boot.
#
# HARDWARE-SPECIFIC:
#   • mt7925e.disable_aspm=1: For MediaTek WiFi 7 chips only. Harmless but
#     unnecessary on other systems. Verification skipped if driver not present.
#   • KERNEL=="card[0-9]": Udev rule matches card0-9. Pattern card[0-9]* would also
#     match control nodes (card0-0) causing failures. Systems with 10+ GPUs are rare;
#     the DRIVERS=="amdgpu" filter ensures only AMD GPUs are affected regardless of
#     card number assignment (which varies based on driver load order).
#
# SECURITY CONSIDERATIONS:
#   • split_lock_detect=off: Creates DoS vulnerability for gaming performance.
#     Only acceptable on single-user gaming desktops.
#   • tsc=reliable: Safe on modern AMD with constant_tsc flag. Verify support
#     with: grep constant_tsc /proc/cpuinfo
#   • loader.conf editor=no: Prevents boot-time param editing but doesn't stop
#     live USB attacks. Full protection requires Secure Boot.
#
# WIFI CONFIGURATION:
#   • iwd is hard-required when 99-cachyos-nm.conf (wifi.backend=iwd) is deployed.
#   • Do NOT enable iwd.service - NetworkManager manages iwd internally.
#   • wpa_supplicant remains installed as fallback; remove 99-cachyos-nm.conf
#     to restore wpa_supplicant backend if iwd issues occur.
#   • WiFi reconnection is performed last because backend switch may disconnect.
#
# SYSTEMD TIMEOUTS:
#   • 30s start / 15s stop+abort is safer than 5s for first-boot scenarios.
#   • Individual services can override with TimeoutStartSec= in their unit files.
#
# OTHER NOTES:
#   • yay package: Available in CachyOS repos only (not vanilla Arch).
#   • PROTON_USE_NTSYNC=1: Requires kernel 6.13+ with CONFIG_NTSYNC.
#   • MESA_SHADER_CACHE_MAX_SIZE=12G: Assumes ample storage; reduce on smaller drives.
#   • eval in _run(): Required for command string parsing. All inputs are controlled
#     by this script; user-provided values are escaped.
#   • No automatic rollback: Backup created at ~/.backup; manual restore required.
#   • Log files accumulate: Clean periodically with: rm ~/cachyos-dots-*.log
#
# FILE FORMAT:
#   • All files maintain POSIX compliance (trailing newline at EOF)
#   • Blank lines within code blocks use intentional whitespace for readability
#   • Do not strip trailing whitespace from blank lines within functions
#
# ══════════════════════════════════════════════════════════════════════════════

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              GLOBAL CONFIGURATION                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -g VERSION "1.0"
set -g DRY false
set -g ALL false

# Determine script directory (required for locating config files)
set -g DIR (cd (dirname (status filename)) 2>/dev/null; and pwd)
if test -z "$DIR"
    echo "Error: Cannot determine script directory" >&2
    exit 1
end

# Generate unique timestamp for log file
set -g TIMESTAMP (date +%Y%m%d-%H%M%S)

# Handle missing HOME (rare edge case: containers, broken PAM)
if test -z "$HOME"
    set -g HOME (getent passwd (id -u) 2>/dev/null | cut -d: -f6)
    if test -z "$HOME"
        echo "Error: Cannot determine HOME directory" >&2
        echo "Set HOME environment variable and retry" >&2
        exit 1
    end
end

# Output paths
set -g BACKUP_DIR "$HOME/.backup"
set -g LOG_FILE "$HOME/cachyos-dots-$TIMESTAMP.log"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              FILE MAPPINGS                                   ║
# ║                                                                              ║
# ║  Format: "source_file:destination_directory/"                               ║
# ║  These define which files are installed and where they go.                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# System configuration files (require sudo)
set -g SYSTEM_FILES \
    "loader.conf:/boot/loader/" \
    "99-cachyos-udev.rules:/etc/udev/rules.d/" \
    "99-cachyos-modprobe.conf:/etc/modprobe.d/" \
    "environment:/etc/" \
    "main.conf:/etc/iwd/" \
    "mkinitcpio.conf:/etc/" \
    "99-cachyos-modules.conf:/etc/modules-load.d/" \
    "99-cachyos-resolved.conf:/etc/systemd/resolved.conf.d/" \
    "sdboot-manage.conf:/etc/" \
    "99-cachyos-system.conf:/etc/systemd/system.conf.d/" \
    "99-cachyos-user.conf:/etc/systemd/user.conf.d/" \
    "99-cachyos-nm.conf:/etc/NetworkManager/conf.d/" \
    "wireless-regdom:/etc/conf.d/"

# Optional fallback service for udev timing issue (Arch bug #72655)
# The 99-cachyos-udev.rules udev rule may fail silently on boot because
# the sysfs attribute doesn't exist when the rule triggers. This service runs
# after graphical.target as a reliable fallback.
# Symptom: cat /sys/class/drm/card*/device/power_dpm_force_performance_level shows "auto"
# Fix: Install this service with --all or answer 'y' when prompted
set -g OPTIONAL_SERVICE "amdgpu-performance.service:/etc/systemd/system/"

# EPP service for CPU performance - sets governor and Energy Performance Preference
# Symptom: [FAIL] EPP: balance_performance (expected: performance)
set -g EPP_SERVICE "cpupower-epp.service:/etc/systemd/system/"

# User configuration files (no sudo required)
set -g USER_FILES \
    "10-ssh-auth-sock.conf:$HOME/.config/environment.d/" \
    "10-ssh-auth-sock.fish:$HOME/.config/fish/conf.d/"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              PACKAGE LISTS                                   ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Packages to install
# iwd:                 Modern WiFi daemon (preinstalled on CachyOS - replaces wpa_supplicant as NM backend)
# libcamera:           Camera/webcam support
# mkinitcpio-firmware: Additional firmware for initramfs warnings
# smartmontools:       Disk health monitoring (preinstalled on CachyOS, not used by installer)
# nvme-cli:            NVMe drive management
# htop:                Interactive process viewer
# unzip:               Archive extraction (preinstalled on CachyOS)
# cpupower:            CPU frequency tools (preinstalled on CachyOS)
# xorg-xrdb:           X11/XWayland resource database (compatibility)
set -g PKGS_ADD libcamera mkinitcpio-firmware nvme-cli htop xorg-xrdb pkgfile plocate cachyos-gaming-meta cachyos-gaming-applications

# Packages to remove (conflicts or unnecessary)
# power-profiles-daemon:        Conflicts with manual CPU governor management
# plymouth:                     Boot splash (unnecessary, slows boot)
# cachyos-plymouth-bootanimation: Plymouth theme
# ufw:                          Firewall (use nftables directly if needed)
# ananicy-cpp:                  Process scheduler (conflicts with manual tuning)
set -g PKGS_DEL power-profiles-daemon plymouth cachyos-plymouth-bootanimation ufw ananicy-cpp

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              SYSTEMD SERVICES                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Services to mask (disable completely)
# lvm2-monitor.service:           LVM monitoring (skip if no LVM)
# ModemManager.service:           Mobile broadband modems (unused on desktop)
# NetworkManager-wait-online:     Delays boot waiting for network
# sleep.target:                   Sleep/suspend targets (desktop stays on)
# suspend.target:                 (masked for always-on desktop)
# hibernate.target:               (masked - requires resume hook if enabled)
# hybrid-sleep.target:            (masked)
# suspend-then-hibernate.target:  (masked)
set -g MASK \
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

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              KERNEL PARAMETERS                               ║
# ║                                                                              ║
# ║  These are set in /etc/sdboot-manage.conf LINUX_OPTIONS                     ║
# ║  and applied to /proc/cmdline after reboot.                                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -g KERNEL_PARAMS \
    8250.nr_uarts=0 \
    amd_iommu=off \
    amd_pstate=active \
    amdgpu.cwsr_enable=0 \
    amdgpu.gpu_recovery=1 \
    amdgpu.modeset=1 \
    amdgpu.ppfeaturemask=0xfffd7fff \
    amdgpu.runpm=0 \
    audit=0 \
    btusb.enable_autosuspend=n \
    mt7925e.disable_aspm=1 \
    nmi_watchdog=0 \
    nowatchdog \
    nvme_core.default_ps_max_latency_us=0 \
    pci=pcie_bus_perf \
    quiet \
    split_lock_detect=off \
    tsc=reliable \
    usbcore.autosuspend=-1 \
    zswap.enabled=0

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              ENVIRONMENT VARIABLES                           ║
# ║                                                                              ║
# ║  These are set in /etc/environment and apply to all sessions.               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -g ENV_VARS \
    "AMD_VULKAN_ICD=RADV" \
    "RADV_PERFTEST=sam" \
    "MESA_SHADER_CACHE_MAX_SIZE=12G" \
    "PROTON_USE_NTSYNC=1" \
    "PROTON_NO_WM_DECORATION=1"

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              MKINITCPIO HOOKS                                ║
# ║                                                                              ║
# ║  Expected hook order in /etc/mkinitcpio.conf                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -g MKINITCPIO_HOOKS \
    base \
    systemd \
    autodetect \
    microcode \
    modconf \
    kms \
    keyboard \
    sd-vconsole \
    block \
    filesystems \
    fsck

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              LOGGING FUNCTIONS                               ║
# ║                                                                              ║
# ║  All output is logged to $LOG_FILE for troubleshooting.                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Internal logging (to file only)
function _log
    echo "["(date '+%Y-%m-%d %H:%M:%S')"] $argv" >> "$LOG_FILE"
end

# Success message (green [OK])
function _ok
    set_color green; echo -n "[OK]"; set_color normal; echo " $argv"
    _log "OK: $argv"
end

# Failure message (red [FAIL])
function _fail
    set_color red; echo -n "[FAIL]"; set_color normal; echo " $argv"
    _log "FAIL: $argv"
end

# Informational message (blue [INFO])
function _info
    set_color blue; echo -n "[INFO]"; set_color normal; echo " $argv"
    _log "INFO: $argv"
end

# Warning message (yellow [WARN])
function _warn
    set_color yellow; echo -n "[WARN]"; set_color normal; echo " $argv"
    _log "WARN: $argv"
end

# Error message (red [ERR] to stderr)
function _err
    set_color red; echo -n "[ERR]"; set_color normal; echo " $argv" >&2
    _log "ERR: $argv"
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              COMMAND EXECUTION                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Execute command with logging and dry-run support
# Note: eval is required here because _run receives command strings (e.g., "sudo pacman -S pkg")
# that must be parsed into executable commands. All inputs are controlled by this script;
# user-provided values (WiFi SSID/passphrase) are escaped before reaching here.
function _run
    set -l log_cmd "$argv"
    
    # Redact sensitive data from logs
    if string match -q '*--passphrase*' "$argv"
        set log_cmd (string replace -r -- '--passphrase [^ ]+' '--passphrase [REDACTED]' "$argv")
    end
    
    _log "RUN: $log_cmd"
    
    if test "$DRY" = true
        set_color cyan; echo -n "[DRY]"; set_color normal; echo " $log_cmd"
        _log "DRY: (not executed)"
        return 0
    else
        set -l output (eval $argv 2>&1)
        set -l ret $status
        if test -n "$output"
            echo "$output"
            _log "OUTPUT: $output"
        end
        _log "EXIT: $ret"
        return $ret
    end
end

# Interactive prompt (respects --all flag for unattended mode)
function _ask
    if test "$ALL" = true
        _log "ASK: $argv[1] -> auto-yes"
        return 0
    end
    read -P "[?] $argv[1] [y/N] " r
    _log "ASK: $argv[1] -> $r"
    string match -qi 'y*' "$r"
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              VERIFICATION HELPERS                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Check if expected value matches actual value
function _chk
    _log "CHECK: $argv[3] - expected='$argv[1]' actual='$argv[2]'"
    if test "$argv[1]" = "$argv[2]"
        _ok "$argv[3]: $argv[2]"
        return 0
    else
        _fail "$argv[3]: $argv[2] (expected: $argv[1])"
        return 1
    end
end

# Check if file exists
function _chk_file
    _log "CHECK FILE: $argv[1]"
    if test -f "$argv[1]"
        _ok "File exists: $argv[1]"
        return 0
    end
    _fail "File NOT FOUND: $argv[1]"
    return 1
end

# Check if pattern exists in file
function _chk_grep
    _log "CHECK GREP: $argv[1] for '$argv[2]'"
    if grep -q "$argv[2]" "$argv[1]" 2>/dev/null
        _ok "  $argv[3]: present"
        return 0
    else
        _fail "  $argv[3]: MISSING"
        return 1
    end
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              DEPENDENCY CHECK                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function check_deps
    _log "Checking dependencies..."
    set -l missing
    
    # Required commands for this installer
    for cmd in pacman systemctl mkinitcpio udevadm sysctl sdboot-manage
        if not command -q $cmd
            set -a missing $cmd
        end
    end
    
    if test (count $missing) -gt 0
        _err "Missing required commands: $missing"
        if contains sdboot-manage $missing
            _err "  sdboot-manage is required for CachyOS bootloader management"
            _err "  Install with: sudo pacman -S sdboot-manage"
        end
        return 1
    end
    
    _log "All dependencies satisfied"
    return 0
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              BACKUP FUNCTIONS                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Backup a file before overwriting
# Arguments: $1 = destination path, $2 = use_sudo (true/false)
function backup_file
    set -l dst $argv[1]
    set -l use_sudo $argv[2]

    # Skip if file doesn't exist
    if not test -f "$dst"
        return 0
    end

    # Determine backup path based on original location
    set -l bp
    if string match -q "$HOME/*" "$dst"
        set bp "$BACKUP_DIR/home/"(string replace "$HOME/" "" "$dst")
    else if string match -q "/boot/*" "$dst"
        set bp "$BACKUP_DIR/boot/"(string replace "/boot/" "" "$dst")
    else
        set bp "$BACKUP_DIR/etc/"(string replace "/etc/" "" "$dst")
    end

    _log "BACKUP: $dst -> $bp"
    
    if test "$DRY" = true
        set_color cyan; echo "[DRY] backup $dst"; set_color normal
        return 0
    end

    # Create backup directory
    if not mkdir -p (dirname "$bp")
        _err "Failed to create backup directory: "(dirname "$bp")
        return 1
    end

    # Perform backup
    if test "$use_sudo" = true
        if not sudo cp "$dst" "$bp"
            _err "Failed to backup: $dst"
            return 1
        end
    else
        if not cp "$dst" "$bp"
            _err "Failed to backup: $dst"
            return 1
        end
    end
    
    return 0
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              FILE INSTALLATION                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

# Install files from a file list
# Arguments: $1 = SYSTEM_FILES or USER_FILES, $2 = use_sudo (true/false)
function install_files
    set -l files
    if test "$argv[1]" = SYSTEM_FILES
        set files $SYSTEM_FILES
    else
        set files $USER_FILES
    end
    set -l use_sudo $argv[2]
    
    _log "INSTALL FILES: $argv[1] (sudo=$use_sudo)"

    for mapping in $files
        set -l p (string split ':' "$mapping")
        set -l src $p[1]
        set -l dst $p[2]

        # Verify source file exists
        if not test -f "$DIR/$src"
            _err "Source file missing: $src"
            continue
        end

        # ════════════════════════════════════════════════════════════════════
        # DEPENDENCY CHECKS
        # Skip files that require packages not yet installed
        # ════════════════════════════════════════════════════════════════════
        
        # 99-cachyos-nm.conf requires iwd package
        if test "$src" = "99-cachyos-nm.conf"
            if not pacman -Qi iwd >/dev/null 2>&1
                _warn "Skipping $src: iwd package not installed"
                _warn "  Install iwd first: sudo pacman -S iwd"
                continue
            end
        end

        # main.conf requires iwd package
        if test "$src" = "main.conf"
            if not pacman -Qi iwd >/dev/null 2>&1
                _warn "Skipping $src: iwd package not installed"
                _warn "  Install iwd first: sudo pacman -S iwd"
                continue
            end
        end

        # ════════════════════════════════════════════════════════════════════
        # INSTALL FILE
        # ════════════════════════════════════════════════════════════════════
        
        # Construct full destination path
        set -l full_dst "$dst"
        if string match -q '*/' "$dst"
            set full_dst "$dst$src"
        end

        # Create destination directory
        set -l dir (dirname "$full_dst")
        if test "$use_sudo" = true
            if not _run "sudo mkdir -p '$dir'"
                _fail "Cannot create directory: $dir"
                continue
            end
        else
            if not _run "mkdir -p '$dir'"
                _fail "Cannot create directory: $dir"
                continue
            end
        end

        # Backup existing file
        backup_file "$full_dst" "$use_sudo"

        # Copy file
        if test "$use_sudo" = true
            if _run "sudo cp '$DIR/$src' '$full_dst'"
                _ok "$src → $full_dst"
            else
                _fail "$src → $full_dst (copy failed)"
            end
        else
            if _run "cp '$DIR/$src' '$full_dst'"
                _ok "$src → $full_dst"
            else
                _fail "$src → $full_dst (copy failed)"
            end
        end
    end
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              DIFF FUNCTION                                   ║
# ║                                                                              ║
# ║  Compares repository files against installed system files.                  ║
# ║  Useful for checking what has changed or needs updating.                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function do_diff
    _log "=== DIFF START ==="
    _info "Comparing repository files against system..."
    echo

    set -l has_diff false
    
    for mapping in $SYSTEM_FILES $USER_FILES
        set -l p (string split ':' "$mapping")
        set -l src $p[1]
        set -l dst $p[2]

        # Construct full destination path
        if string match -q '*/' "$dst"
            set dst "$dst$src"
        end

        # Check source exists
        if not test -f "$DIR/$src"
            _err "Repository file missing: $src"
            continue
        end

        # Compare files
        if test -f "$dst"
            if not diff -q "$DIR/$src" "$dst" >/dev/null 2>&1
                set has_diff true
                _warn "DIFFERS: $src"
                diff --color=auto "$DIR/$src" "$dst" | tee -a "$LOG_FILE"
                echo
            end
        else
            set has_diff true
            _fail "NOT INSTALLED: $dst"
        end
    end

    # Check optional service (amdgpu-performance.service)
    set -l p (string split ':' "$OPTIONAL_SERVICE")
    set -l svc_src $p[1]
    set -l svc_dst $p[2]$p[1]
    if test -f "$DIR/$svc_src"
        if test -f "$svc_dst"
            if not diff -q "$DIR/$svc_src" "$svc_dst" >/dev/null 2>&1
                set has_diff true
                _warn "DIFFERS: $svc_src (optional)"
                diff --color=auto "$DIR/$svc_src" "$svc_dst" | tee -a "$LOG_FILE"
                echo
            end
        else
            _info "NOT INSTALLED (optional): $svc_dst"
        end
    end

    # Check EPP service (cpupower-epp.service)
    set -l p2 (string split ':' "$EPP_SERVICE")
    set -l epp_src $p2[1]
    set -l epp_dst $p2[2]$p2[1]
    if test -f "$DIR/$epp_src"
        if test -f "$epp_dst"
            if not diff -q "$DIR/$epp_src" "$epp_dst" >/dev/null 2>&1
                set has_diff true
                _warn "DIFFERS: $epp_src"
                diff --color=auto "$DIR/$epp_src" "$epp_dst" | tee -a "$LOG_FILE"
                echo
            end
        else
            set has_diff true
            _fail "NOT INSTALLED: $epp_dst"
        end
    end

    if test "$has_diff" = false
        _ok "All files match system!"
    end
    
    _log "=== DIFF END ==="
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              STATIC VERIFICATION                             ║
# ║                                                                              ║
# ║  Verifies configuration files exist and contain expected values.            ║
# ║  Does not require running services or hardware access.                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function verify_static
    _log "=== STATIC VERIFICATION START ==="
    _info "Static verification (config files)..."
    _info "This checks that files exist and contain expected values."
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # BOOT CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "BOOT CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── mkinitcpio.conf ─────────────────────────────────────────────────────────
    echo "── mkinitcpio.conf ──"
    _log "CHECK: mkinitcpio.conf"
    if _chk_file /etc/mkinitcpio.conf
        # Check MODULES array
        set -l m (grep '^MODULES=' /etc/mkinitcpio.conf 2>/dev/null)
        echo "  Config: $m"
        _log "MODULES: $m"
        
        if string match -q '*amdgpu*' "$m"
            _ok "  amdgpu: present (early KMS)"
        else
            _fail "  amdgpu: MISSING (required for early KMS)"
        end
        
        if string match -q '*nvme*' "$m"
            _ok "  nvme: present (NVMe boot support)"
        else
            _fail "  nvme: MISSING (required for NVMe boot)"
        end

        # Check HOOKS array
        set -l h (grep '^HOOKS=' /etc/mkinitcpio.conf 2>/dev/null)
        echo "  Config: $h"
        _log "HOOKS: $h"
        
        for hook in $MKINITCPIO_HOOKS
            if string match -q "*$hook*" "$h"
                _ok "  $hook: present"
            else
                _fail "  $hook: MISSING"
            end
        end

        # Check COMPRESSION
        set -l comp (grep '^COMPRESSION=' /etc/mkinitcpio.conf 2>/dev/null | cut -d'"' -f2)
        _chk zstd "$comp" "COMPRESSION"
    end
    echo

    # ── loader.conf ─────────────────────────────────────────────────────────────
    echo "── loader.conf (systemd-boot) ──"
    _log "CHECK: loader.conf"
    
    # /boot/loader/ may require elevated permissions
    if test -f /boot/loader/loader.conf; or sudo test -f /boot/loader/loader.conf
        _ok "File exists: /boot/loader/loader.conf"
        set -l content (cat /boot/loader/loader.conf 2>/dev/null; or sudo cat /boot/loader/loader.conf 2>/dev/null)
        
        if string match -q '*default @saved*' "$content"
            _ok "  default @saved: present (remembers last selection)"
        else
            _fail "  default @saved: MISSING"
        end
        
        if string match -q '*timeout 0*' "$content"
            _ok "  timeout 0: present (no menu delay)"
        else
            _fail "  timeout 0: MISSING"
        end
        
        if string match -q '*console-mode keep*' "$content"
            _ok "  console-mode keep: present"
        else
            _fail "  console-mode keep: MISSING"
        end
        
        if string match -q '*editor no*' "$content"
            _ok "  editor no: present (security hardening)"
        else
            _warn "  editor no: MISSING (allows boot parameter modification)"
        end
    else
        _fail "File NOT FOUND: /boot/loader/loader.conf"
    end
    echo

    # ── sdboot-manage.conf ──────────────────────────────────────────────────────
    echo "── sdboot-manage.conf (kernel cmdline) ──"
    _log "CHECK: sdboot-manage.conf"
    if _chk_file /etc/sdboot-manage.conf
        set -l opts (grep '^LINUX_OPTIONS=' /etc/sdboot-manage.conf 2>/dev/null)
        _log "LINUX_OPTIONS: $opts"
        
        if test -n "$opts"
            _ok "LINUX_OPTIONS: defined"
        else
            _fail "LINUX_OPTIONS: NOT FOUND"
        end
        
        for param in $KERNEL_PARAMS
            # mt7925e.disable_aspm=1: Hardware-specific for MediaTek WiFi 7
            # Skip verification if driver not present to avoid false warnings
            if test "$param" = "mt7925e.disable_aspm=1"
                if not test -d /sys/module/mt7925e; and not modinfo mt7925e >/dev/null 2>&1
                    _info "  $param: skipped (mt7925e driver not present)"
                    continue
                end
            end
            
            if string match -q "*$param*" "$opts"
                _ok "  $param: present"
            else
                _fail "  $param: MISSING"
            end
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # GPU/CPU CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "GPU/CPU CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── 99-cachyos-udev.rules (GPU + ntsync) ─────────────────────────────────────
    echo "── 99-cachyos-udev.rules (udev) ──"
    _log "CHECK: udev rules"
    if _chk_file /etc/udev/rules.d/99-cachyos-udev.rules
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'power_dpm_force_performance_level' "GPU power_dpm rule"
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'ACTION=="add"' "ACTION==add trigger"
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'SUBSYSTEM=="drm"' "SUBSYSTEM==drm match"
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'DRIVERS=="amdgpu"' "AMDGPU driver match"
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'KERNEL=="ntsync"' "ntsync kernel match"
        _chk_grep /etc/udev/rules.d/99-cachyos-udev.rules 'MODE="0666"' "ntsync MODE=0666"
    end
    echo

    # ── 99-cachyos-modules.conf (module autoload) ───────────────────────────────
    echo "── 99-cachyos-modules.conf (module autoload) ──"
    _log "CHECK: ntsync module autoload"
    if _chk_file /etc/modules-load.d/99-cachyos-modules.conf
        _chk_grep /etc/modules-load.d/99-cachyos-modules.conf '^ntsync$' "ntsync module entry"
    end
    echo

    # ── amdgpu-performance.service (optional) ───────────────────────────────────
    echo "── amdgpu-performance.service (optional fallback) ──"
    _log "CHECK: amdgpu-performance.service"
    set -l svc_path /etc/systemd/system/amdgpu-performance.service
    if test -f "$svc_path"
        _ok "File exists: $svc_path"
        _chk_grep "$svc_path" 'power_dpm_force_performance_level' "GPU DPM command"
        _chk_grep "$svc_path" 'After=graphical.target' "Runs after graphical.target"
        _chk_grep "$svc_path" 'Type=oneshot' "Service type oneshot"
        _chk_grep "$svc_path" 'RemainAfterExit=yes' "RemainAfterExit=yes"
        _chk_grep "$svc_path" 'ConditionPathIsDirectory=/sys/class/drm' "Condition: /sys/class/drm exists"
        _chk_grep "$svc_path" 'WantedBy=graphical.target' "WantedBy graphical.target"
        
        # Check if enabled
        set -l svc_state (systemctl is-enabled amdgpu-performance.service 2>/dev/null)
        if test "$svc_state" = enabled
            _ok "  Service: enabled"
        else
            _warn "  Service: $svc_state (recommend: enabled)"
        end
    else
        _info "File not installed: $svc_path (optional - install if udev rule fails)"
    end
    echo

    # ── cpupower-epp.service (required for performance mode) ─────────────────────
    echo "── cpupower-epp.service (CPU performance) ──"
    _log "CHECK: cpupower-epp.service"
    set -l epp_path /etc/systemd/system/cpupower-epp.service
    if test -f "$epp_path"
        _ok "File exists: $epp_path"
        _chk_grep "$epp_path" 'energy_performance_preference' "EPP setting command"
        _chk_grep "$epp_path" 'scaling_governor' "Governor setting command"
        _chk_grep "$epp_path" 'After=cpupower.service' "Runs after cpupower.service"
        _chk_grep "$epp_path" 'Wants=cpupower.service' "Wants cpupower.service"
        _chk_grep "$epp_path" 'Type=oneshot' "Service type oneshot"
        _chk_grep "$epp_path" 'RemainAfterExit=yes' "RemainAfterExit=yes"
        _chk_grep "$epp_path" 'WantedBy=multi-user.target' "WantedBy multi-user.target"
        
        # Check if enabled
        set -l epp_state (systemctl is-enabled cpupower-epp.service 2>/dev/null)
        if test "$epp_state" = enabled
            _ok "  Service: enabled"
        else
            _fail "  Service: $epp_state (expected: enabled)"
        end
    else
        _fail "File NOT FOUND: $epp_path (required for performance governor/EPP)"
    end
    echo

    # ── /etc/environment ────────────────────────────────────────────────────────
    echo "── /etc/environment (global env vars) ──"
    _log "CHECK: environment"
    if _chk_file /etc/environment
        for exp in $ENV_VARS
            set -l n (string split '=' "$exp")[1]
            set -l v (string split '=' "$exp")[2]
            set -l a (grep "^$n=" /etc/environment 2>/dev/null)
            if test "$a" = "$exp"
                _ok "  $n=$v"
            else if test -n "$a"
                _fail "  $n: $a (expected: $exp)"
            else
                _fail "  $n: NOT SET (expected: $exp)"
            end
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # MODULE CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "MODULE CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── 99-cachyos-modprobe.conf (combined modprobe config) ─────────────────────
    echo "── 99-cachyos-modprobe.conf (modprobe) ──"
    _log "CHECK: modprobe config"
    if _chk_file /etc/modprobe.d/99-cachyos-modprobe.conf
        # Blacklist checks
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'blacklist sp5100_tco' "sp5100_tco blacklisted"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'install sp5100_tco /usr/bin/true' "sp5100_tco install disabled"
        # AMDGPU checks
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'options amdgpu' "options amdgpu line"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'modeset=1' "modeset=1"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'cwsr_enable=0' "cwsr_enable=0"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'gpu_recovery=1' "gpu_recovery=1"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'runpm=0' "runpm=0"
        # MT7925e check (optional - only for WiFi 7 hardware)
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'options mt7925e' "options mt7925e line"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'disable_aspm=1' "mt7925e ASPM disabled"
        # USB/Bluetooth autosuspend (DUAL with cmdline)
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'options btusb' "options btusb line"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'enable_autosuspend=n' "btusb autosuspend disabled"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'options usbcore' "options usbcore line"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'autosuspend=-1' "usbcore autosuspend disabled"
        # NVMe power saving (DUAL with cmdline)
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'options nvme_core' "options nvme_core line"
        _chk_grep /etc/modprobe.d/99-cachyos-modprobe.conf 'default_ps_max_latency_us=0' "nvme_core APST disabled"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # NETWORK CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "NETWORK CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── main.conf (iwd) ─────────────────────────────────────────────────────────
    echo "── main.conf (iwd) ──"
    _log "CHECK: iwd"
    if test -f /etc/iwd/main.conf
        _ok "File exists: /etc/iwd/main.conf"
        
        # Check [General] section
        _chk_grep /etc/iwd/main.conf '\[General\]' "[General] section"
        _chk_grep /etc/iwd/main.conf 'EnableNetworkConfiguration=false' "EnableNetworkConfiguration=false"
        
        # Check [DriverQuirks] section
        _chk_grep /etc/iwd/main.conf '\[DriverQuirks\]' "[DriverQuirks] section"
        _chk_grep /etc/iwd/main.conf 'DefaultInterface=\*' "DefaultInterface=*"
        set -l psd (grep '^PowerSaveDisable=' /etc/iwd/main.conf 2>/dev/null)
        if test -n "$psd"
            _ok "  PowerSaveDisable: "(string replace 'PowerSaveDisable=' '' "$psd")
        else
            _fail "  PowerSaveDisable: not set (expected: * or driver list)"
        end
        
        # Check [Network] section
        _chk_grep /etc/iwd/main.conf '\[Network\]' "[Network] section"
        _chk_grep /etc/iwd/main.conf 'NameResolvingService=systemd' "NameResolvingService=systemd"
    else
        if pacman -Qi iwd >/dev/null 2>&1
            _fail "File NOT FOUND: /etc/iwd/main.conf (iwd is installed)"
        else
            _info "File not installed: /etc/iwd/main.conf (iwd not installed)"
        end
    end
    echo

    # ── 99-cachyos-nm.conf (NetworkManager) ─────────────────────────────────────
    echo "── 99-cachyos-nm.conf (NetworkManager) ──"
    _log "CHECK: NetworkManager config"
    if test -f /etc/NetworkManager/conf.d/99-cachyos-nm.conf
        _ok "File exists: /etc/NetworkManager/conf.d/99-cachyos-nm.conf"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf '\[device\]' "[device] section"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf 'wifi.backend=iwd' "wifi.backend=iwd"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf '\[connection\]' "[connection] section"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf 'wifi.powersave=2' "wifi.powersave=2 (disabled)"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf '\[logging\]' "[logging] section"
        _chk_grep /etc/NetworkManager/conf.d/99-cachyos-nm.conf 'level=ERR' "level=ERR (errors only)"
    else
        _fail "File NOT FOUND: /etc/NetworkManager/conf.d/99-cachyos-nm.conf"
    end
    echo

    # ── wireless-regdom ─────────────────────────────────────────────────────────
    echo "── wireless-regdom (regulatory domain) ──"
    _log "CHECK: wireless-regdom"
    if _chk_file /etc/conf.d/wireless-regdom
        set -l regdom (grep '^WIRELESS_REGDOM=' /etc/conf.d/wireless-regdom 2>/dev/null | cut -d'"' -f2)
        if test -n "$regdom"
            _ok "  WIRELESS_REGDOM: $regdom"
        else
            _fail "  WIRELESS_REGDOM: not set"
        end
    end
    echo

    # ── 99-cachyos-resolved.conf ────────────────────────────────────────────────────────────
    echo "── 99-cachyos-resolved.conf (systemd-resolved) ──"
    _log "CHECK: no-mdns"
    if _chk_file /etc/systemd/resolved.conf.d/99-cachyos-resolved.conf
        _chk_grep /etc/systemd/resolved.conf.d/99-cachyos-resolved.conf 'MulticastDNS=no' "MulticastDNS=no (avahi conflict fix)"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # SYSTEMD CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "SYSTEMD CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── 99-cachyos-system.conf ────────────────────────────────────────────────────
    echo "── 99-cachyos-system.conf (system services) ──"
    _log "CHECK: system timeouts"
    if _chk_file /etc/systemd/system.conf.d/99-cachyos-system.conf
        set -l v_start (grep "^DefaultTimeoutStartSec=" /etc/systemd/system.conf.d/99-cachyos-system.conf 2>/dev/null)
        if test "$v_start" = "DefaultTimeoutStartSec=30s"
            _ok "  DefaultTimeoutStartSec=30s"
        else
            _fail "  $v_start (expected: DefaultTimeoutStartSec=30s)"
        end
        
        set -l v_stop (grep "^DefaultTimeoutStopSec=" /etc/systemd/system.conf.d/99-cachyos-system.conf 2>/dev/null)
        if test "$v_stop" = "DefaultTimeoutStopSec=15s"
            _ok "  DefaultTimeoutStopSec=15s"
        else
            _fail "  $v_stop (expected: DefaultTimeoutStopSec=15s)"
        end
        
        set -l v_abort (grep "^DefaultTimeoutAbortSec=" /etc/systemd/system.conf.d/99-cachyos-system.conf 2>/dev/null)
        if test "$v_abort" = "DefaultTimeoutAbortSec=15s"
            _ok "  DefaultTimeoutAbortSec=15s"
        else
            _fail "  $v_abort (expected: DefaultTimeoutAbortSec=15s)"
        end
    end
    echo

    # ── 99-cachyos-user.conf ──────────────────────────────────────────────────────
    echo "── 99-cachyos-user.conf (user services) ──"
    _log "CHECK: user timeouts"
    if _chk_file /etc/systemd/user.conf.d/99-cachyos-user.conf
        set -l v_start (grep "^DefaultTimeoutStartSec=" /etc/systemd/user.conf.d/99-cachyos-user.conf 2>/dev/null)
        if test "$v_start" = "DefaultTimeoutStartSec=30s"
            _ok "  DefaultTimeoutStartSec=30s"
        else
            _fail "  $v_start (expected: DefaultTimeoutStartSec=30s)"
        end
        
        set -l v_stop (grep "^DefaultTimeoutStopSec=" /etc/systemd/user.conf.d/99-cachyos-user.conf 2>/dev/null)
        if test "$v_stop" = "DefaultTimeoutStopSec=15s"
            _ok "  DefaultTimeoutStopSec=15s"
        else
            _fail "  $v_stop (expected: DefaultTimeoutStopSec=15s)"
        end
        
        set -l v_abort (grep "^DefaultTimeoutAbortSec=" /etc/systemd/user.conf.d/99-cachyos-user.conf 2>/dev/null)
        if test "$v_abort" = "DefaultTimeoutAbortSec=15s"
            _ok "  DefaultTimeoutAbortSec=15s"
        else
            _fail "  $v_abort (expected: DefaultTimeoutAbortSec=15s)"
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # USER CONFIGURATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "USER CONFIGURATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── 10-ssh-auth-sock.conf ───────────────────────────────────────────────────
    echo "── 10-ssh-auth-sock.conf (systemd environment) ──"
    _log "CHECK: SSH agent (systemd)"
    if test -f ~/.config/environment.d/10-ssh-auth-sock.conf
        _ok "File exists: ~/.config/environment.d/10-ssh-auth-sock.conf"
        set -l v (grep '^SSH_AUTH_SOCK=' ~/.config/environment.d/10-ssh-auth-sock.conf 2>/dev/null)
        if string match -q '*XDG_RUNTIME_DIR*ssh-agent.socket*' "$v"
            _ok "  SSH_AUTH_SOCK: correctly configured"
        else
            _fail "  SSH_AUTH_SOCK: $v (expected XDG_RUNTIME_DIR pattern)"
        end
    else
        _fail "File NOT FOUND: ~/.config/environment.d/10-ssh-auth-sock.conf"
    end
    echo

    # ── 10-ssh-auth-sock.fish ───────────────────────────────────────────────────
    echo "── 10-ssh-auth-sock.fish (fish shell) ──"
    _log "CHECK: SSH agent (fish)"
    if test -f ~/.config/fish/conf.d/10-ssh-auth-sock.fish
        _ok "File exists: ~/.config/fish/conf.d/10-ssh-auth-sock.fish"
        if grep -q 'set -gx SSH_AUTH_SOCK' ~/.config/fish/conf.d/10-ssh-auth-sock.fish
            _ok "  set -gx SSH_AUTH_SOCK: present"
        else
            _fail "  set -gx SSH_AUTH_SOCK: MISSING"
        end
        if grep -q 'XDG_RUNTIME_DIR.*ssh-agent' ~/.config/fish/conf.d/10-ssh-auth-sock.fish
            _ok "  XDG_RUNTIME_DIR socket path: present"
        else
            _warn "  XDG_RUNTIME_DIR socket path: MISSING (hardcoded path?)"
        end
        if grep -q 'status is-interactive' ~/.config/fish/conf.d/10-ssh-auth-sock.fish
            _ok "  Interactive check: present"
        else
            _warn "  Interactive check: MISSING (may set in non-interactive shells)"
        end
    else
        _fail "File NOT FOUND: ~/.config/fish/conf.d/10-ssh-auth-sock.fish"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # SERVICE STATUS
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "SERVICE STATUS"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Masked services ─────────────────────────────────────────────────────────
    echo "── Masked services ──"
    _log "CHECK: masked services"
    for svc in $MASK
        set -l s (systemctl is-enabled "$svc" 2>/dev/null)
        if test "$s" = masked
            _ok "  $svc: masked"
        else
            _fail "  $svc: $s (expected: masked)"
        end
    end
    echo

    # ── Enabled services ────────────────────────────────────────────────────────
    echo "── Enabled services ──"
    _log "CHECK: enabled services"
    
    for svc in fstrim.timer cpupower-epp.service
        set -l state (systemctl is-enabled "$svc" 2>/dev/null)
        if test "$state" = enabled
            _ok "  $svc: enabled"
        else
            _fail "  $svc: $state (expected: enabled)"
        end
    end

    # Check optional amdgpu-performance.service
    if test -f /etc/systemd/system/amdgpu-performance.service
        set -l state (systemctl is-enabled amdgpu-performance.service 2>/dev/null)
        if test "$state" = enabled
            _ok "  amdgpu-performance.service: enabled (optional)"
        else
            _info "  amdgpu-performance.service: $state (optional - enable if udev fails)"
        end
    end

    # User service (socket activation shows as indirect)
    set -l ssh_state (systemctl --user is-enabled ssh-agent.service 2>/dev/null)
    if test "$ssh_state" = enabled -o "$ssh_state" = indirect
        _ok "  ssh-agent.service (user): $ssh_state"
    else
        _fail "  ssh-agent.service (user): $ssh_state (expected: enabled or indirect)"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # PACKAGE STATUS
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "PACKAGE STATUS"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Installed packages ──────────────────────────────────────────────────────
    echo "── Required packages ──"
    _log "CHECK: installed packages"
    for pkg in $PKGS_ADD
        if pacman -Qi "$pkg" >/dev/null 2>&1
            _ok "  $pkg: installed"
        else
            _fail "  $pkg: NOT installed"
        end
    end
    echo

    # ── Removed packages ────────────────────────────────────────────────────────
    echo "── Removed packages (conflicts) ──"
    _log "CHECK: removed packages"
    for pkg in $PKGS_DEL
        if pacman -Qi "$pkg" >/dev/null 2>&1
            _fail "  $pkg: STILL installed (should be removed)"
        else
            _ok "  $pkg: removed"
        end
    end
    echo

    _log "=== STATIC VERIFICATION END ==="
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              RUNTIME VERIFICATION                            ║
# ║                                                                              ║
# ║  Verifies live system state (requires reboot after installation).           ║
# ║  Checks actual kernel parameters, hardware state, running services.         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function verify_runtime
    _log "=== RUNTIME VERIFICATION START ==="
    _info "Runtime verification (live system state)..."
    _info "Note: Run this AFTER rebooting to verify changes took effect."
    _warn "Values are point-in-time snapshots; transient changes during verification are possible."
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # CPU FEATURES
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "CPU FEATURES"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Microcode ───────────────────────────────────────────────────────────────
    echo "── Microcode ──"
    _log "CHECK: microcode"
    if dmesg 2>/dev/null | grep -q 'microcode:'
        _ok "Microcode: loaded"
        dmesg | grep 'microcode:' | head -1 | sed 's/^/  /'
    else if journalctl -k -b 2>/dev/null | grep -q 'microcode:'
        _ok "Microcode: loaded (via journalctl)"
    else
        _warn "Microcode: NOT FOUND (run with sudo for dmesg access)"
    end
    echo

    # ── TSC (Time Stamp Counter) ────────────────────────────────────────────────
    echo "── TSC (Time Stamp Counter) ──"
    _log "CHECK: constant_tsc"
    if grep -q 'constant_tsc' /proc/cpuinfo 2>/dev/null
        _ok "constant_tsc: present (tsc=reliable is safe)"
    else
        _warn "constant_tsc: NOT FOUND - tsc=reliable may cause timing issues"
        _warn "  Consider using tsc=nowatchdog instead"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # BOOT VERIFICATION
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "BOOT VERIFICATION"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Initramfs ───────────────────────────────────────────────────────────────
    echo "── Initramfs ──"
    _log "CHECK: initramfs"
    
    set -l img (find /boot -maxdepth 1 -name 'initramfs-linux*.img' ! -name '*fallback*' 2>/dev/null | head -1)
    if test -z "$img"
        set img (sudo find /boot -maxdepth 1 -name 'initramfs-linux*.img' ! -name '*fallback*' 2>/dev/null | head -1)
    end
    
    if test -n "$img"
        echo "  File: $img"
        _log "INITRAMFS: $img"
        
        set -l t (file "$img" 2>/dev/null)
        if test -z "$t"
            set t (sudo file "$img" 2>/dev/null)
        end
        _log "FILE TYPE: $t"
        
        # Check compression type
        if string match -q '*Zstandard*' "$t"
            _ok "Compression: ZSTD"
        else if string match -q '*cpio*' "$t"
            # Microcode prepended as uncompressed cpio
            set -l cfg_comp (grep '^COMPRESSION=' /etc/mkinitcpio.conf 2>/dev/null | cut -d'"' -f2)
            if test "$cfg_comp" = "zstd"
                _ok "Compression: ZSTD (microcode prepended as uncompressed cpio)"
            else
                _warn "Compression: $cfg_comp (expected: zstd)"
            end
        else if string match -q '*LZ4*' "$t"
            _warn "Compression: LZ4 (expected: ZSTD)"
        else if string match -q '*gzip*' "$t"
            _warn "Compression: gzip (expected: ZSTD)"
        else
            _info "Type: $t"
        end
    else
        _warn "Initramfs: NOT FOUND (check /boot permissions)"
    end
    
    # Check that expected modules are included in initramfs
    if test -n "$img"; and command -q lsinitcpio
        _log "CHECK: initramfs modules"
        set -l init_mods (lsinitcpio -a "$img" 2>/dev/null; or sudo lsinitcpio -a "$img" 2>/dev/null)
        if test -n "$init_mods"
            if echo "$init_mods" | grep -q 'amdgpu'
                _ok "  Module included: amdgpu"
            else
                _fail "  Module included: amdgpu MISSING"
            end
            if echo "$init_mods" | grep -q 'nvme'
                _ok "  Module included: nvme"
            else
                _fail "  Module included: nvme MISSING"
            end
        else
            _warn "  Could not list initramfs contents (try with sudo)"
        end
    end
    echo

    # ── Kernel cmdline ──────────────────────────────────────────────────────────
    echo "── Kernel cmdline (active) ──"
    _log "CHECK: cmdline"
    
    set -l cmd (cat /proc/cmdline)
    echo "  $cmd" | fold -s -w 70 | sed 's/^/  /'
    _log "CMDLINE: $cmd"
    echo
    
    for p in $KERNEL_PARAMS
        # Skip hardware-specific params if hardware not present
        if test "$p" = "mt7925e.disable_aspm=1"
            if not test -d /sys/module/mt7925e; and not modinfo mt7925e >/dev/null 2>&1
                _info "  $p: skipped (mt7925e driver not present)"
                continue
            end
        end
        
        if string match -q "*$p*" "$cmd"
            _ok "  $p: present"
        else
            _fail "  $p: MISSING"
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # GPU/CPU PERFORMANCE STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "GPU/CPU PERFORMANCE STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── GPU DPM ─────────────────────────────────────────────────────────────────
    echo "── GPU power_dpm_force_performance_level ──"
    _log "CHECK: GPU DPM"
    
    set -l gpu_ok true
    set -l found_gpu false
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level
        # Skip if glob didn't expand (no matching files)
        if not test -f "$card"
            continue
        end
        set found_gpu true
        set -l level (cat "$card" 2>/dev/null)
        set -l card_name (echo "$card" | sed 's|.*/\(card[0-9]*\)/.*|\1|')
        _log "GPU DPM $card_name: $level"
        
        if test "$level" = high
            _ok "  $card_name: $level"
        else
            set gpu_ok false
            _fail "  $card_name: $level (expected: high)"
        end
    end
    
    if test "$found_gpu" = false
        _warn "  No GPU DPM sysfs entries found"
    else if test "$gpu_ok" = false
        _warn "  GPU not at 'high' - possible udev timing race (Arch bug #72655)"
        _warn "  Fix: sudo systemctl enable --now amdgpu-performance.service"
    end
    echo

    # ── CPU performance ─────────────────────────────────────────────────────────
    echo "── CPU performance state ──"
    _log "CHECK: CPU performance"
    
    for check in "scaling_driver:amd-pstate-epp:Scaling driver" \
                 "scaling_governor:performance:Governor" \
                 "energy_performance_preference:performance:EPP"
        set -l c (string split ':' "$check")
        set -l v (cat "/sys/devices/system/cpu/cpu0/cpufreq/$c[1]" 2>/dev/null)
        _log "CPU $c[1]: $v"
        
        if test "$v" = "$c[2]"
            _ok "  $c[3]: $v"
        else
            _fail "  $c[3]: $v (expected: $c[2])"
        end
    end
    echo

    # ── SAM/ReBAR ───────────────────────────────────────────────────────────────
    echo "── SAM/ReBAR (Smart Access Memory) ──"
    _log "CHECK: SAM/ReBAR"
    
    set -l rebar_status (dmesg 2>/dev/null | grep -i rebar)
    if test -n "$rebar_status"
        if echo "$rebar_status" | grep -qi "enabled\|BAR 0.*\[mem\]"
            _ok "SAM/ReBAR: enabled"
            _log "ReBAR dmesg: $rebar_status"
        else
            _warn "SAM/ReBAR: found in dmesg but status unclear"
            _log "ReBAR dmesg: $rebar_status"
        end
    else
        set -l rebar_sysfs (cat /sys/bus/pci/devices/*/resource0_resize 2>/dev/null | head -1)
        if test -n "$rebar_sysfs"
            _ok "SAM/ReBAR: resize supported (sysfs)"
            _log "ReBAR sysfs: $rebar_sysfs"
        else
            _warn "SAM/ReBAR: not detected (may require BIOS enable)"
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # MODULE STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "MODULE STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Blacklisted modules ─────────────────────────────────────────────────────
    echo "── Blacklisted modules ──"
    _log "CHECK: blacklisted modules"
    
    if lsmod | grep -q '^sp5100_tco '
        _fail "  sp5100_tco: LOADED (should be blacklisted)"
    else
        _ok "  sp5100_tco: not loaded"
    end
    echo

    # ── Module parameters (DUAL verification) ───────────────────────────────────
    echo "── Module parameters ──"
    _log "CHECK: module parameters"
    
    # btusb autosuspend
    if test -f /sys/module/btusb/parameters/enable_autosuspend
        set -l v (cat /sys/module/btusb/parameters/enable_autosuspend 2>/dev/null)
        if test "$v" = "N"
            _ok "  btusb.enable_autosuspend: $v"
        else
            _fail "  btusb.enable_autosuspend: $v (expected: N)"
        end
    else
        _info "  btusb: module not loaded (no Bluetooth hardware?)"
    end
    
    # usbcore autosuspend
    if test -f /sys/module/usbcore/parameters/autosuspend
        set -l v (cat /sys/module/usbcore/parameters/autosuspend 2>/dev/null)
        if test "$v" = "-1"
            _ok "  usbcore.autosuspend: $v"
        else
            _fail "  usbcore.autosuspend: $v (expected: -1)"
        end
    else
        _warn "  usbcore: parameter not found"
    end
    
    # nvme_core APST
    if test -f /sys/module/nvme_core/parameters/default_ps_max_latency_us
        set -l v (cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null)
        if test "$v" = "0"
            _ok "  nvme_core.default_ps_max_latency_us: $v"
        else
            _fail "  nvme_core.default_ps_max_latency_us: $v (expected: 0)"
        end
    else
        _info "  nvme_core: module not loaded (no NVMe drives?)"
    end
    
    # nmi_watchdog (sysctl)
    if test -f /proc/sys/kernel/nmi_watchdog
        set -l v (cat /proc/sys/kernel/nmi_watchdog 2>/dev/null)
        if test "$v" = "0"
            _ok "  kernel.nmi_watchdog: $v"
        else
            _fail "  kernel.nmi_watchdog: $v (expected: 0)"
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # SERVICE STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "SERVICE STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Running services ────────────────────────────────────────────────────────
    echo "── Running services ──"
    _log "CHECK: service status"
    
    # cpupower-epp.service sets EPP to performance (oneshot, RemainAfterExit=yes)
    set -l epp_state (systemctl is-active cpupower-epp.service 2>/dev/null)
    if test "$epp_state" = active -o "$epp_state" = exited
        _ok "  cpupower-epp.service: $epp_state"
    else if test -f /etc/systemd/system/cpupower-epp.service
        _fail "  cpupower-epp.service: $epp_state (expected: active or exited)"
    else
        _warn "  cpupower-epp.service: not installed (governor/EPP may not be performance)"
    end

    if systemctl is-active fstrim.timer 2>/dev/null | grep -q active
        _ok "  fstrim.timer: active"
    else
        _fail "  fstrim.timer: NOT active"
    end

    # Check optional amdgpu-performance.service
    if test -f /etc/systemd/system/amdgpu-performance.service
        if systemctl is-active amdgpu-performance.service 2>/dev/null | grep -q active
            _ok "  amdgpu-performance.service: active (optional)"
        else
            set -l state (systemctl is-active amdgpu-performance.service 2>/dev/null)
            _info "  amdgpu-performance.service: $state (optional)"
        end
    end

    # ssh-agent uses socket activation
    set -l ssh_sock "$XDG_RUNTIME_DIR/ssh-agent.socket"
    if test -S "$ssh_sock"
        _ok "  ssh-agent: socket ready at $ssh_sock"
    else if systemctl --user is-active ssh-agent.service 2>/dev/null | grep -q active
        _ok "  ssh-agent: service active"
    else
        _fail "  ssh-agent: socket missing at $ssh_sock"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # ENVIRONMENT STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "ENVIRONMENT STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Environment variables ───────────────────────────────────────────────────
    echo "── Environment variables ──"
    _log "CHECK: env vars"
    
    for exp in $ENV_VARS
        set -l n (string split '=' "$exp")[1]
        set -l expected (string split '=' "$exp")[2]
        set -l actual (printenv "$n")
        _log "ENV $n: $actual"
        
        if test "$actual" = "$expected"
            _ok "  $n=$actual"
        else if test -n "$actual"
            _fail "  $n=$actual (expected: $expected)"
        else
            _fail "  $n: NOT SET (expected: $expected)"
        end
    end
    echo

    # ── ntsync support ──────────────────────────────────────────────────────────
    echo "── ntsync support (kernel 6.13+) ──"
    _log "CHECK: ntsync"
    
    if test -c /dev/ntsync
        _ok "ntsync: /dev/ntsync exists"
    else if lsmod | grep -q '^ntsync '
        _warn "ntsync: module loaded but /dev/ntsync missing"
    else if test -f /proc/config.gz
        if zgrep -q 'CONFIG_NTSYNC=y' /proc/config.gz 2>/dev/null
            _warn "ntsync: CONFIG=y but /dev/ntsync missing"
        else if zgrep -q 'CONFIG_NTSYNC=m' /proc/config.gz 2>/dev/null
            _info "ntsync: CONFIG=m, try: sudo modprobe ntsync"
        else
            _info "ntsync: NOT available (kernel 6.13+ required)"
        end
    else
        _info "ntsync: cannot determine (no /proc/config.gz)"
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # WIFI STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "WIFI STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── WiFi backend ────────────────────────────────────────────────────────────
    echo "── WiFi backend ──"
    _log "CHECK: WiFi"

    # Detect WiFi interface
    set -l wlan_iface ""
    for iface in /sys/class/net/*/wireless
        if test -d "$iface"
            set wlan_iface (basename (dirname "$iface"))
            break
        end
    end
    
    if test -n "$wlan_iface"
        _ok "  WiFi interface: $wlan_iface"
        _log "WIFI_IFACE: $wlan_iface"
    else
        _warn "  WiFi interface: NOT DETECTED"
        _log "WIFI_IFACE: not found"
    end

    if pgrep -x iwd >/dev/null
        _ok "  iwd process: running"
    else
        _fail "  iwd process: NOT running"
    end
    
    # Check regulatory domain
    set -l reg (iw reg get 2>/dev/null | awk '/^country/ {gsub(/:/, "", $2); print $2}' | head -1)
    set -l expected_regdom (grep '^WIRELESS_REGDOM=' /etc/conf.d/wireless-regdom 2>/dev/null | cut -d'"' -f2)
    if test -z "$expected_regdom"
        set expected_regdom "US"
    end
    _log "REGDOM: $reg"
    
    if test "$reg" = "$expected_regdom"
        _ok "  Regulatory domain: $reg"
    else if test -n "$reg"
        _fail "  Regulatory domain: $reg (expected: $expected_regdom)"
    else
        _warn "  Regulatory domain: NOT DETECTED"
    end
    
    # Check WiFi power save state (should be off)
    if test -n "$wlan_iface"
        set -l ps_state (iw dev "$wlan_iface" get power_save 2>/dev/null | awk '{print $NF}')
        _log "WIFI_POWERSAVE: $ps_state"
        if test "$ps_state" = "off"
            _ok "  Power save: off"
        else if test -n "$ps_state"
            _fail "  Power save: $ps_state (expected: off)"
        else
            _warn "  Power save: could not determine"
        end
    end
    echo

    # ════════════════════════════════════════════════════════════════════════════
    # SYSTEMD RUNTIME STATE
    # ════════════════════════════════════════════════════════════════════════════

    echo "══════════════════════════════════════════════════════════════════════"
    echo "SYSTEMD RUNTIME STATE"
    echo "══════════════════════════════════════════════════════════════════════"
    echo

    # ── Journal disk usage ──────────────────────────────────────────────────────
    echo "── Journal disk usage ──"
    _log "CHECK: journal disk usage"
    set -l journal_usage (journalctl --disk-usage 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | head -1)
    _log "JOURNAL_USAGE: $journal_usage"
    if test -n "$journal_usage"
        _info "  Disk usage: $journal_usage"
    else
        _warn "  Disk usage: could not determine"
    end
    echo

    # ── Systemd timeouts ────────────────────────────────────────────────────────
    echo "── Systemd timeouts (runtime) ──"
    _log "CHECK: systemd timeouts"
    
    echo "  System:"
    set -l v_start (systemctl show --property=DefaultTimeoutStartUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT system DefaultTimeoutStartUSec: $v_start"
    if test "$v_start" = 30s
        _ok "    DefaultTimeoutStartUSec: $v_start"
    else
        _fail "    DefaultTimeoutStartUSec: $v_start (expected: 30s)"
    end
    
    set -l v_stop (systemctl show --property=DefaultTimeoutStopUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT system DefaultTimeoutStopUSec: $v_stop"
    if test "$v_stop" = 15s
        _ok "    DefaultTimeoutStopUSec: $v_stop"
    else
        _fail "    DefaultTimeoutStopUSec: $v_stop (expected: 15s)"
    end
    
    set -l v_abort (systemctl show --property=DefaultTimeoutAbortUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT system DefaultTimeoutAbortUSec: $v_abort"
    if test "$v_abort" = 15s
        _ok "    DefaultTimeoutAbortUSec: $v_abort"
    else
        _fail "    DefaultTimeoutAbortUSec: $v_abort (expected: 15s)"
    end
    
    echo "  User:"
    set -l v_start_u (systemctl --user show --property=DefaultTimeoutStartUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT user DefaultTimeoutStartUSec: $v_start_u"
    if test "$v_start_u" = 30s
        _ok "    DefaultTimeoutStartUSec: $v_start_u"
    else
        _fail "    DefaultTimeoutStartUSec: $v_start_u (expected: 30s)"
    end
    
    set -l v_stop_u (systemctl --user show --property=DefaultTimeoutStopUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT user DefaultTimeoutStopUSec: $v_stop_u"
    if test "$v_stop_u" = 15s
        _ok "    DefaultTimeoutStopUSec: $v_stop_u"
    else
        _fail "    DefaultTimeoutStopUSec: $v_stop_u (expected: 15s)"
    end
    
    set -l v_abort_u (systemctl --user show --property=DefaultTimeoutAbortUSec 2>/dev/null | cut -d= -f2)
    _log "TIMEOUT user DefaultTimeoutAbortUSec: $v_abort_u"
    if test "$v_abort_u" = 15s
        _ok "    DefaultTimeoutAbortUSec: $v_abort_u"
    else
        _fail "    DefaultTimeoutAbortUSec: $v_abort_u (expected: 15s)"
    end
    echo

    # ── Journal usage ───────────────────────────────────────────────────────────
    echo "── Journal usage ──"
    _log "CHECK: journal"
    
    echo "  Current usage:"
    journalctl --disk-usage 2>/dev/null | tee -a "$LOG_FILE" | sed 's/^/    /'
    echo

    # ── Console/Keymap ──────────────────────────────────────────────────────────
    echo "── Console/Keymap ──"
    _log "CHECK: console"
    
    set -l km (localectl status 2>/dev/null | awk '/VC Keymap:/ {print $3}')
    _log "KEYMAP: $km"
    
    if test "$km" = us
        _ok "  VC Keymap: $km"
    else
        _info "  VC Keymap: $km"
    end
    
    set -l x11 (localectl status 2>/dev/null | awk '/X11 Layout:/ {print $3}')
    _info "  X11 Layout: $x11"
    echo

    # ── SSH agent ───────────────────────────────────────────────────────────────
    echo "── SSH agent ──"
    _log "CHECK: SSH agent"
    
    if test -n "$SSH_AUTH_SOCK"
        _ok "  SSH_AUTH_SOCK: $SSH_AUTH_SOCK"
    else
        _fail "  SSH_AUTH_SOCK: NOT SET"
    end
    
    set -l sp "$XDG_RUNTIME_DIR/ssh-agent.socket"
    if test -S "$sp"
        _ok "  Socket exists: $sp"
    else
        _fail "  Socket missing: $sp"
        _info "    Enable: systemctl --user enable --now ssh-agent.service"
    end
    echo

    _log "=== RUNTIME VERIFICATION END ==="
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              MAIN INSTALLATION                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function do_install
    _log "=== INSTALLATION START ==="
    _log "VERSION: $VERSION"
    _log "DRY: $DRY"
    _log "ALL: $ALL"
    _log "DIR: $DIR"

    echo
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                     CachyOS Dotfiles Installer v$VERSION                       ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo
    
    if test "$DRY" = true
        _warn "DRY-RUN MODE - No changes will be made"
        echo
    end

    # ════════════════════════════════════════════════════════════════════════════
    # PRE-FLIGHT CHECKS
    # ════════════════════════════════════════════════════════════════════════════

    if not test -f "$DIR/mkinitcpio.conf"
        _err "Run from repository directory (mkinitcpio.conf not found)"
        exit 1
    end

    if test "$DRY" = false
        if not sudo -v
            _err "Sudo required for installation"
            exit 1
        end
        if not check_deps
            exit 1
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # CREATE BACKUP DIRECTORY
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Creating backup directory..."
    _log "BACKUP_DIR: $BACKUP_DIR"
    
    if test "$DRY" = true
        _info "Would create backup dir: $BACKUP_DIR"
    else
        set -l backup_dirs \
            "$BACKUP_DIR/boot/loader" \
            "$BACKUP_DIR/etc/udev/rules.d" \
            "$BACKUP_DIR/etc/modprobe.d" \
            "$BACKUP_DIR/etc/modules-load.d" \
            "$BACKUP_DIR/etc/iwd" \
            "$BACKUP_DIR/etc/systemd/system" \
            "$BACKUP_DIR/etc/systemd/resolved.conf.d" \
            "$BACKUP_DIR/etc/systemd/system.conf.d" \
            "$BACKUP_DIR/etc/systemd/user.conf.d" \
            "$BACKUP_DIR/etc/NetworkManager/conf.d" \
            "$BACKUP_DIR/etc/conf.d" \
            "$BACKUP_DIR/home/.config/environment.d" \
            "$BACKUP_DIR/home/.config/fish/conf.d"

        for dir in $backup_dirs
            if not mkdir -p "$dir" 2>/dev/null
                _err "Failed to create backup directory: $dir"
                return 1
            end
        end
        _ok "Backup directory: $BACKUP_DIR"
    end

    # ════════════════════════════════════════════════════════════════════════════
    # PACKAGE INSTALLATION
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Package installation..."
    
    # Detect CachyOS and add yay if available
    set -l pkgs_to_install $PKGS_ADD
    if grep -q '\[cachyos\]' /etc/pacman.conf 2>/dev/null
        set -a pkgs_to_install yay
        _info "CachyOS detected: including yay"
    else
        _info "Vanilla Arch detected: skipping yay (use paru for AUR)"
    end
    
    if test "$ALL" = true
        _warn "Unattended mode: packages will be installed without confirmation"
    end
    
    if _ask "Install packages? ($pkgs_to_install)"
        if test (count $pkgs_to_install) -gt 0
            _run "sudo pacman -S --needed --noconfirm -- $pkgs_to_install"
        else
            _warn "No packages to install"
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # SECURITY WARNING
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _warn "╔════════════════════════════════════════════════════════════════════════════╗"
    _warn "║  SECURITY NOTICE: split_lock_detect=off                                    ║"
    _warn "║                                                                            ║"
    _warn "║  This kernel parameter creates a DoS vulnerability where malicious        ║"
    _warn "║  software can degrade system performance via split lock abuse.            ║"
    _warn "║                                                                            ║"
    _warn "║  ONLY acceptable on single-user gaming desktops.                          ║"
    _warn "║  Remove from sdboot-manage.conf on multi-user or server systems.          ║"
    _warn "╚════════════════════════════════════════════════════════════════════════════╝"
    
    if not _ask "Continue with split_lock_detect=off? (gaming desktop only)"
        _info "Edit $DIR/sdboot-manage.conf to remove split_lock_detect=off"
        _info "Then re-run this installer"
        return 1
    end

    # ════════════════════════════════════════════════════════════════════════════
    # SYSTEM FILES INSTALLATION
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Installing system configuration files..."
    install_files SYSTEM_FILES true

    # ════════════════════════════════════════════════════════════════════════════
    # LUKS ENCRYPTION CHECK
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Checking for disk encryption..."
    
    set -l has_luks false
    if lsblk -o FSTYPE 2>/dev/null | grep -q 'crypto_LUKS'
        set has_luks true
    else if test -f /etc/crypttab; and grep -qv '^#' /etc/crypttab 2>/dev/null
        set has_luks true
    end

    if test "$has_luks" = true
        _warn "╔════════════════════════════════════════════════════════════════════════════╗"
        _warn "║  LUKS ENCRYPTION DETECTED                                                  ║"
        _warn "║                                                                            ║"
        _warn "║  The sd-encrypt hook MUST be added to mkinitcpio.conf or your system      ║"
        _warn "║  will NOT BOOT after reboot!                                              ║"
        _warn "╚════════════════════════════════════════════════════════════════════════════╝"
        
        if _ask "Add sd-encrypt hook to mkinitcpio.conf? (REQUIRED for LUKS)"
            if test "$DRY" = true
                set_color cyan; echo "[DRY] Would add sd-encrypt hook before filesystems"; set_color normal
            else
                _run "sudo sed -i 's/\\(block\\) \\(filesystems\\)/\\1 sd-encrypt \\2/' /etc/mkinitcpio.conf"
                _ok "Added sd-encrypt hook to mkinitcpio.conf"
            end
        else
            _err "╔════════════════════════════════════════════════════════════════════════════╗"
            _err "║  ABORTING: Cannot safely continue on LUKS system                          ║"
            _err "║  System would be UNBOOTABLE after reboot without sd-encrypt hook          ║"
            _err "╚════════════════════════════════════════════════════════════════════════════╝"
            _err "To proceed, re-run installer and accept sd-encrypt installation"
            _err "Or manually add 'sd-encrypt' before 'filesystems' in /etc/mkinitcpio.conf"
            return 1
        end
    else
        _ok "No LUKS encryption detected"
    end

    # ════════════════════════════════════════════════════════════════════════════
    # WIRELESS REGULATORY DOMAIN
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Wireless regulatory domain configuration..."
    _info "Current setting: US (United States)"
    _info "Common codes: US, GB, DE, FR, JP, AU, CA, CN"
    
    if not test "$ALL" = true
        read -P "[?] Enter your country code (or press Enter for US): " regdom_input
        if test -n "$regdom_input"
            set -l regdom_upper (string upper "$regdom_input")
            
            # Validate ISO 3166-1 alpha-2 format
            if not string match -qr '^[A-Z]{2}$' "$regdom_upper"
                _err "Invalid country code: '$regdom_input' (must be 2 letters, e.g., US, GB, DE)"
                _info "Keeping default: US"
            else if test "$DRY" = true
                set_color cyan; echo "[DRY] Would set WIRELESS_REGDOM=\"$regdom_upper\""; set_color normal
            else
                _run "sudo sed -i 's/WIRELESS_REGDOM=\"US\"/WIRELESS_REGDOM=\"$regdom_upper\"/' /etc/conf.d/wireless-regdom"
                _ok "Set regulatory domain to: $regdom_upper"
            end
        else
            _ok "Keeping default: US"
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # USER FILES INSTALLATION
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Installing user configuration files..."
    install_files USER_FILES false

    # ════════════════════════════════════════════════════════════════════════════
    # AMDGPU PERFORMANCE SERVICE (OPTIONAL BUT RECOMMENDED)
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "AMDGPU performance service (STRONGLY RECOMMENDED)..."
    _warn "  The udev rule (99-cachyos-udev.rules) may fail silently on boot"
    _warn "  due to driver initialization timing (Arch bug #72655)."
    _warn "  This service ensures GPU power_dpm is set to 'high' after graphical.target."
    
    if _ask "Install amdgpu-performance.service? (strongly recommended)"
        set -l p (string split ':' "$OPTIONAL_SERVICE")
        set -l src $p[1]
        set -l dst $p[2]$p[1]
        
        if test -f "$DIR/$src"
            _run "sudo mkdir -p '"(dirname $dst)"'"
            backup_file "$dst" true
            if _run "sudo cp '$DIR/$src' '$dst'"
                _ok "$src → $dst"
                _run "sudo systemctl enable amdgpu-performance.service"
            else
                _fail "$src → $dst (copy failed)"
            end
        else
            _err "Source file missing: $src"
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # FSTAB OPTIMIZATION (OPTIONAL)
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "fstab optimization (optional)..."
    _warn "  NOTE: Only modifies /, /boot, /tmp entries with standard format"
    _warn "  Complex entries (bind mounts, btrfs subvol) may need manual editing"

    # Early safety check: Detect btrfs/complex mount options
    set -l complex_root (grep -E '^[^#]+[[:space:]]+/[[:space:]]' /etc/fstab 2>/dev/null | grep -oE 'subvol=[^,[:space:]]*|compress=[^,[:space:]]*|space_cache[^,[:space:]]*')
    
    if test -n "$complex_root"
        _warn "╔════════════════════════════════════════════════════════════════════════════╗"
        _warn "║  BTRFS OPTIONS DETECTED - SKIPPING AUTOMATIC MODIFICATION                  ║"
        _warn "╚════════════════════════════════════════════════════════════════════════════╝"
        _info "Detected: $complex_root"
        _info "Manual edit required. Add to root mount: noatime,lazytime,commit=60"
    else
        # Validate fstab format
        set -l fstab_valid true
        set -l fstab_warnings

        if grep -E '^[^#].*subvol=' /etc/fstab 2>/dev/null | grep -qE '[[:space:]]/(boot)?[[:space:]]'
            set fstab_valid false
            set -a fstab_warnings "btrfs subvolumes detected on / or /boot"
        end

        if grep -E '^[^#].*bind' /etc/fstab 2>/dev/null | grep -qE '[[:space:]]/(boot|tmp)?[[:space:]]'
            set fstab_valid false
            set -a fstab_warnings "bind mounts detected on target paths"
        end

        if not grep -qE '^[^#]+[[:space:]]+/[[:space:]]+' /etc/fstab 2>/dev/null
            set fstab_valid false
            set -a fstab_warnings "root (/) mount not found in expected format"
        end

        if test "$fstab_valid" = false
            _warn "fstab format validation failed:"
            for w in $fstab_warnings
                _warn "  - $w"
            end
            _warn "Automatic modification may corrupt fstab. Manual editing recommended."
        else if _ask "Optimize fstab mount options? (noatime, lazytime, commit=60)"
            _run "sudo cp /etc/fstab /etc/fstab.bak"
            _info "Backup: /etc/fstab.bak"
            
            if test "$DRY" = false
                _info "Preview:"
                set -l fstab_preview (mktemp)
                sudo sed -E \
                    -e 's/^(\S+[[:space:]]+\/boot[[:space:]]+\S+[[:space:]]+)\S+/\1defaults,umask=0077/' \
                    -e 's/^(\S+[[:space:]]+\/[[:space:]]+\S+[[:space:]]+)\S+/\1defaults,noatime,lazytime,commit=60/' \
                    -e 's/^(\S+[[:space:]]+\/tmp[[:space:]]+\S+[[:space:]]+)\S+/\1defaults,noatime,lazytime,mode=1777/' \
                    /etc/fstab > "$fstab_preview" 2>/dev/null
                diff --color=auto /etc/fstab "$fstab_preview" 2>/dev/null; or echo "  (no changes detected)"
                rm -f "$fstab_preview"
            end
            
            if _ask "Apply fstab changes? (review diff above carefully)"
                _run "sudo sed -i -E \
                    -e 's/^(\\S+[[:space:]]+\\/boot[[:space:]]+\\S+[[:space:]]+)\\S+/\\1defaults,umask=0077/' \
                    -e 's/^(\\S+[[:space:]]+\\/[[:space:]]+\\S+[[:space:]]+)\\S+/\\1defaults,noatime,lazytime,commit=60/' \
                    -e 's/^(\\S+[[:space:]]+\\/tmp[[:space:]]+\\S+[[:space:]]+)\\S+/\\1defaults,noatime,lazytime,mode=1777/' \
                    /etc/fstab"
                _ok "fstab mount options updated"
                _info "Restore if needed: sudo cp /etc/fstab.bak /etc/fstab"
            end
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # COSMIC DESKTOP CONFIGURATION (OPTIONAL)
    # ════════════════════════════════════════════════════════════════════════════

    echo
    if command -q cosmic-comp; or test -d /usr/share/cosmic
        _info "COSMIC desktop detected..."
        
        if _ask "Disable COSMIC auto-suspend on AC power?"
            set -l base "$HOME/.config/cosmic"

            if test "$DRY" = true
                set_color cyan; echo "[DRY] Would disable suspend in $base"; set_color normal
            else
                # Power/Idle - disable suspend on AC
                _run "mkdir -p '$base/com.system76.CosmicIdle/v1'"
                _run "echo 'None' > '$base/com.system76.CosmicIdle/v1/suspend_on_ac_time'"

                _ok "COSMIC auto-suspend disabled"
            end
        end
    else
        _info "COSMIC desktop not detected - skipping COSMIC configuration"
    end

    # ════════════════════════════════════════════════════════════════════════════
    # POST-INSTALLATION TASKS
    # ════════════════════════════════════════════════════════════════════════════

    echo
    _info "Post-installation tasks..."

    # ── Database Updates ────────────────────────────────────────────────────────
    # These improve shell completion and file searching
    
    if _ask "Update plocate database? (sudo updatedb - for locate command)"
        if command -q updatedb
            _run "sudo updatedb"
        else
            _warn "updatedb not found (install plocate package)"
        end
    end

    if _ask "Update pkgfile database? (sudo pkgfile --update - for command-not-found)"
        if command -q pkgfile
            _run "sudo pkgfile --update"
        else
            _warn "pkgfile not found (install pkgfile package)"
        end
    end

    # ── Mirror Ranking ──────────────────────────────────────────────────────────
    # Rank mirrors for faster package downloads
    
    if _ask "Rank CachyOS mirrors? (cachyos-rate-mirrors - faster downloads)"
        if command -q cachyos-rate-mirrors
            _run "sudo cachyos-rate-mirrors"
        else if command -q rate-mirrors
            _warn "Using rate-mirrors (cachyos-rate-mirrors not found)"
            _run "rate-mirrors --allow-resolve --protocol https arch | sudo tee /etc/pacman.d/mirrorlist"
        else
            _warn "No mirror ranking tool found"
            _info "Install with: sudo pacman -S cachyos-rate-mirrors"
        end
    end

    # Create missing session directories
    if _ask "Create missing session directories? (prevents display manager warnings)"
        _run "sudo mkdir -p /usr/share/xsessions /usr/local/share/wayland-sessions /usr/local/share/xsessions"
    end

    # Reload udev rules
    if _ask "Reload udev rules?"
        _run "sudo udevadm control --reload-rules"
        _run "sudo udevadm trigger"
        test "$DRY" = false; and sleep 1
    end

    # Reload sysctl (applies system defaults from /etc/sysctl.d/ if present)
    if _ask "Reload sysctl?"
        _run "sudo sysctl --system"
    end

    # Restart NetworkManager
    if _ask "Restart NetworkManager (switch to iwd backend)?"
        if not pacman -Qi iwd >/dev/null 2>&1
            _err "iwd package not installed - cannot switch backend"
            _info "Install with: sudo pacman -S iwd"
        else
            _run "sudo systemctl restart NetworkManager"
        end
    end

    # Remove conflicting packages
    set -l to_del
    if test "$DRY" = true
        set to_del $PKGS_DEL
    else
        for pkg in $PKGS_DEL
            if pacman -Qi "$pkg" >/dev/null 2>&1
                set -a to_del $pkg
            end
        end
    end

    if test (count $to_del) -gt 0
        if _ask "Remove conflicting packages? ($to_del)"
            _run "sudo pacman -Rns --noconfirm -- $to_del"
        end
    end

    # Mask services (with LVM safety check)
    set -l safe_mask
    set -l has_lvm false
    set -l pvs_output (sudo pvs --noheadings 2>/dev/null | string trim)
    
    if test -n "$pvs_output"
        set has_lvm true
        _warn "╔════════════════════════════════════════════════════════════════════════════╗"
        _warn "║  LVM DETECTED - lvm2 services will NOT be masked                           ║"
        _warn "╚════════════════════════════════════════════════════════════════════════════╝"
        sudo pvs 2>/dev/null | sed 's/^/    /'
        echo
    end
    
    for svc in $MASK
        if string match -q 'lvm2*' "$svc"
            if test "$has_lvm" = true
                _info "  Skipping: $svc (LVM in use)"
                continue
            end
        end
        set -a safe_mask $svc
    end

    if test (count $safe_mask) -gt 0
        if _ask "Mask services? ($safe_mask)"
            _run "sudo systemctl mask -- $safe_mask"
        end
    end

    # ── EPP Service (fixes Governor/EPP verification failures) ──────────────────
    # This service sets both governor AND EPP to "performance" to fix:
    #   [FAIL] Governor: powersave (expected: performance)
    #   [FAIL] EPP: balance_performance (expected: performance)
    
    if _ask "Install and enable cpupower-epp.service? (REQUIRED for performance mode)"
        set -l p (string split ':' "$EPP_SERVICE")
        set -l src $p[1]
        set -l dst $p[2]$p[1]
        
        if test -f "$DIR/$src"
            _run "sudo mkdir -p '"(dirname $dst)"'"
            backup_file "$dst" true
            if _run "sudo cp '$DIR/$src' '$dst'"
                _ok "$src → $dst"
                _run "sudo systemctl daemon-reload"
                _run "sudo systemctl enable --now cpupower-epp.service"
            else
                _fail "$src → $dst (copy failed)"
            end
        else
            _err "Source file missing: $src"
        end
    end

    if _ask "Enable fstrim.timer?"
        _run "sudo systemctl enable --now fstrim.timer"
    end

    if _ask "Enable ssh-agent.service (user)?"
        _run "systemctl --user enable --now ssh-agent.service"
    end

    # Rebuild initramfs
    if _ask "Rebuild initramfs? (required if mkinitcpio.conf changed)"
        if not _run "sudo mkinitcpio -P"
            _err "mkinitcpio failed - check output above"
            _err "System may not boot correctly without valid initramfs"
        end
    end

    # Update bootloader
    if _ask "Update bootloader?"
        if not _run "sudo sdboot-manage gen"
            _err "sdboot-manage gen failed - boot entries may not be updated"
        end
        if not _run "sudo sdboot-manage update"
            _err "sdboot-manage update failed - bootloader may not be updated"
        end
    end

    # Reload systemd
    _run "sudo systemctl daemon-reload"
    _run "systemctl --user daemon-reload"

    # ── Clear Package Cache ─────────────────────────────────────────────────────
    # Free disk space by removing old package versions
    
    if _ask "Clear package cache? (sudo pacman -Sc - removes old versions)"
        _run "sudo pacman -Sc --noconfirm"
    end

    # ════════════════════════════════════════════════════════════════════════════
    # WIFI RECONNECTION (LAST - MAY DISCONNECT)
    # ════════════════════════════════════════════════════════════════════════════

    if _ask "Reconnect WiFi via iwd? (required after backend switch)"
        # Auto-detect WiFi interface
        set -l wlan_iface ""

        # Method 1: iwctl device list
        if test -z "$wlan_iface"
            set wlan_iface (iwctl device list 2>/dev/null | awk '/station/ {print $2; exit}')
        end

        # Method 2: ip link
        if test -z "$wlan_iface"
            set wlan_iface (ip -o link show 2>/dev/null | awk -F': ' '/wl[a-z0-9]+/ {print $2; exit}')
        end

        # Method 3: /sys/class/net
        if test -z "$wlan_iface"
            for iface in /sys/class/net/*/wireless
                if test -d "$iface"
                    set wlan_iface (basename (dirname "$iface"))
                    break
                end
            end
        end

        # Manual entry
        if test -z "$wlan_iface"
            _warn "Could not detect WiFi interface"
            _info "Available interfaces:"
            ip -o link show 2>/dev/null | awk -F': ' '{print "  " $2}'
            read -P "[?] Enter WiFi interface name (or press Enter to skip): " wlan_iface
            
            if test -n "$wlan_iface"
                if not string match -qr '^[a-zA-Z0-9_-]{1,15}$' "$wlan_iface"
                    _err "Invalid interface name: '$wlan_iface'"
                    set wlan_iface ""
                else if not test -d "/sys/class/net/$wlan_iface"
                    _warn "Interface '$wlan_iface' does not exist"
                    if not _ask "Continue anyway?"
                        set wlan_iface ""
                    end
                end
            end
        end

        if test -z "$wlan_iface"
            _warn "Skipping WiFi reconnection (no interface specified)"
        else
            _info "Using WiFi interface: $wlan_iface"
            read -P "[?] WiFi SSID: " wifi_ssid
            
            if test -z "$wifi_ssid"
                _warn "Skipping WiFi reconnection (no SSID provided)"
            else
                read -sP "[?] WiFi passphrase: " wifi_pass
                echo
                
                # Escape special characters for shell safety
                set -l escaped_ssid (string replace -a '\\' '\\\\' -- "$wifi_ssid" | string replace -a "'" "'\\''" | string replace -a '$' '\\$')
                set -l escaped_pass (string replace -a '\\' '\\\\' -- "$wifi_pass" | string replace -a "'" "'\\''" | string replace -a '$' '\\$')
                
                _run "iwctl --passphrase '$escaped_pass' station '$wlan_iface' connect '$escaped_ssid'"
            end
        end
    end

    # ════════════════════════════════════════════════════════════════════════════
    # COMPLETION
    # ════════════════════════════════════════════════════════════════════════════

    echo
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "INSTALLATION COMPLETE"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo
    
    _warn "Manual steps required:"
    _warn "  1. Review /etc/fstab mount options (backup at /etc/fstab.bak)"
    _warn "  2. REBOOT to apply kernel cmdline and module changes"
    echo
    _info "Backup location: $BACKUP_DIR"
    _info "Restore command: sudo cp -r \$BACKUP_DIR/etc/* /etc/; sudo cp -r \$BACKUP_DIR/boot/* /boot/; cp -r \$BACKUP_DIR/home/.config/* ~/.config/"
    echo
    _info "Post-reboot verification: ./ry-install.fish --verify"
    echo
    _ok "Done!"

    _log "=== INSTALLATION END ==="
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              LINT CHECK                                      ║
# ║                                                                              ║
# ║  Validates fish script syntax and checks for common anti-patterns.          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function do_lint
    _log "=== LINT CHECK START ==="
    _info "Running fish syntax check on ry-install.fish..."
    echo

    set -l script_path "$DIR/ry-install.fish"
    set -l has_errors false

    if not command -q fish
        _err "fish shell not found - cannot run lint"
        return 1
    end

    # ── Syntax Check ────────────────────────────────────────────────────────────
    echo "── Fish Syntax Check ──"
    if fish -n "$script_path" 2>&1
        _ok "ry-install.fish: syntax valid"
    else
        set has_errors true
        _fail "ry-install.fish: syntax errors detected"
    end
    echo

    # ── Anti-pattern Check ──────────────────────────────────────────────────────
    echo "── Anti-pattern Check ──"

    # Check for bash-style $() command substitution
    set -l bash_subst (grep -n '\$(' "$script_path" 2>/dev/null | grep -v '#.*\$(' | grep -v 'echo.*\$('; or true)
    if test -n "$bash_subst"
        _warn "Possible bash-style \$() found (should use (command) in fish):"
        echo "$bash_subst" | sed 's/^/  /'
    else
        _ok "No bash-style \$() substitution found"
    end

    # Check for bash-style [[ ]] conditionals
    set -l bash_cond (grep -n '\[\[' "$script_path" 2>/dev/null | grep -v '#' | grep -v 'sed\|grep'; or true)
    if test -n "$bash_cond"
        _fail "Bash-style [[ ]] found (use 'test' or '[ ]' in fish):"
        echo "$bash_cond" | sed 's/^/  /'
        set has_errors true
    else
        _ok "No bash-style [[ ]] conditionals found"
    end

    # Check for bash-style export
    set -l bash_export (grep -n '^[[:space:]]*export ' "$script_path" 2>/dev/null | grep -v '#'; or true)
    if test -n "$bash_export"
        _fail "Bash-style 'export' found (use 'set -gx' in fish):"
        echo "$bash_export" | sed 's/^/  /'
        set has_errors true
    else
        _ok "No bash-style 'export' found"
    end

    # Check for bash-style source
    set -l bash_source (grep -n '^[[:space:]]*source ' "$script_path" 2>/dev/null | grep -v '#'; or true)
    if test -n "$bash_source"
        _fail "Bash-style 'source' found:"
        echo "$bash_source" | sed 's/^/  /'
        set has_errors true
    else
        _ok "No problematic 'source' usage found"
    end

    # Check for && and || logic operators
    set -l bash_logic (grep -n ' && \| || ' "$script_path" 2>/dev/null | grep -v '#' | grep -v 'test\|grep\|awk\|sed\|find\|string\|match\|replace'; or true)
    if test -n "$bash_logic"
        _warn "Possible bash-style && or || found (use 'and'/'or' in fish):"
        echo "$bash_logic" | head -5 | sed 's/^/  /'
        echo "  (showing first 5 matches)"
    else
        _ok "No bash-style && or || logic operators found"
    end
    echo

    if test "$has_errors" = true
        _fail "Lint check completed with errors"
        _log "=== LINT CHECK END (ERRORS) ==="
        return 1
    else
        _ok "Lint check passed"
        _log "=== LINT CHECK END (OK) ==="
        return 0
    end
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              HELP                                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

function show_help
    echo "
╔══════════════════════════════════════════════════════════════════════════════╗
║                     CachyOS Dotfiles Installer v$VERSION                       ║
╚══════════════════════════════════════════════════════════════════════════════╝

Usage: "(status filename)" [OPTIONS]

OPTIONS:
  --all             Install without prompts (unattended mode)
  --dry-run         Preview changes without modifying system
  --diff            Compare repository files against installed system
  --verify          Run full verification (static + runtime)
  --verify-static   Check config files exist with correct content
  --verify-runtime  Check live system state (run after reboot)
  --lint            Run fish syntax and anti-pattern checks
  -h, --help        Show this help
  -v, --version     Show version

EXAMPLES:
  ./ry-install.fish              # Interactive installation
  ./ry-install.fish --dry-run    # Preview all changes
  ./ry-install.fish --all        # Unattended installation
  ./ry-install.fish --diff       # Check what differs from system
  ./ry-install.fish --verify     # Full verification

LOG FILE:
  ~/cachyos-dots-YYYYMMDD-HHMMSS.log

  Note: Log files accumulate over time. Periodically clean up:
        rm ~/cachyos-dots-*.log

KNOWN ISSUES:
  • AMDGPU udev timing (Arch bug #72655): Rule may fail silently on boot.
    If GPU shows 'auto' instead of 'high', install amdgpu-performance.service.
  • mt7925e.disable_aspm=1: Hardware-specific for MediaTek WiFi 7 chips.
    Harmless but unnecessary on other systems. Verification auto-skipped.
"
end

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                              ENTRY POINT                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -l MODE install

for arg in $argv
    switch $arg
        case --all
            set ALL true
        case --dry-run
            set DRY true
        case --diff
            set MODE diff
        case --verify
            set MODE verify
        case --verify-static
            set MODE verify-static
        case --verify-runtime
            set MODE verify-runtime
        case --lint
            set MODE lint
        case -h --help
            show_help
            exit 0
        case -v --version
            echo "v$VERSION"
            exit 0
        case '*'
            _err "Unknown option: $arg"
            echo
            show_help
            exit 1
    end
end

# Change to script directory
if not cd "$DIR"
    _err "Cannot change to script directory"
    exit 1
end

# Initialize log file
echo "# CachyOS Dotfiles Installer v$VERSION" > "$LOG_FILE"
echo "# Started: "(date) >> "$LOG_FILE"
echo "# Command: "(status filename)" $argv" >> "$LOG_FILE"
echo "# Mode: $MODE" >> "$LOG_FILE"
echo "# Dry-run: $DRY" >> "$LOG_FILE"
echo "# Unattended: $ALL" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Execute requested mode
switch $MODE
    case diff
        do_diff
    case verify
        verify_static
        echo
        echo "════════════════════════════════════════════════════════════════════════════════"
        echo
        verify_runtime
    case verify-static
        verify_static
    case verify-runtime
        verify_runtime
    case lint
        do_lint
    case install
        do_install
end

# Finalize log
echo "" >> "$LOG_FILE"
echo "# Finished: "(date) >> "$LOG_FILE"
_info "Log file: $LOG_FILE"
