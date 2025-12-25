#!/usr/bin/env bash
# Thin-Server Module: Core System
# Base packages + FreeRDP 3.17.2 compilation
#
# Dependencies: None (base module)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

MODULE_NAME="core-system"
MODULE_VERSION="$APP_VERSION"

log "═══════════════════════════════════════"
log "Installing: Core System v$MODULE_VERSION"
log "═══════════════════════════════════════"

# ============================================
# VALIDATE SYSTEM REQUIREMENTS
# ============================================
validate_system_requirements() {
    log "Validating system requirements..."

    local requirements_met=true

    #Check OS
    log "  Checking operating system..."
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        log "    OS: $PRETTY_NAME"

        # Check if Debian
        if [[ "$ID" != "debian" ]]; then
            warn "    Not Debian! This system is designed for Debian 12+"
            warn "    Current OS: $ID $VERSION_ID"
            warn "    Proceed at your own risk!"
        fi

        # Check Debian version
        if [[ "$ID" == "debian" ]]; then
            local version_num=$(echo "$VERSION_ID" | cut -d. -f1)
            if [ "$version_num" -lt 11 ]; then
                error "    Debian $VERSION_ID is too old (require Debian 11+)"
                requirements_met=false
            else
                log "    ✓ Debian $VERSION_ID (supported)"
            fi
        fi
    else
        warn "    Cannot detect OS version (/etc/os-release missing)"
    fi

    #Check CPU cores
    log "  Checking CPU..."
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    log "    CPU cores: $cpu_cores"
    if [ "$cpu_cores" -lt 2 ]; then
        warn "    Only $cpu_cores CPU core(s). Recommended: 2+"
        warn "    FreeRDP compilation will be slow!"
    else
        log "    ✓ $cpu_cores cores available"
    fi

    #Check RAM
    log "  Checking memory..."
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    local total_ram_gb=$(echo "scale=1; $total_ram_mb / 1024" | bc 2>/dev/null || echo "?")

    log "    Total RAM: ${total_ram_mb} MB (${total_ram_gb} GB)"

    if [ "$total_ram_mb" -lt 1024 ]; then
        error "    Insufficient RAM: ${total_ram_mb} MB (minimum: 1024 MB)"
        requirements_met=false
    elif [ "$total_ram_mb" -lt 2048 ]; then
        warn "    Low RAM: ${total_ram_mb} MB (recommended: 2048+ MB)"
    else
        log "    ✓ ${total_ram_mb} MB RAM available"
    fi

    #Check available disk space
    log "  Checking disk space..."
    local root_avail_kb=$(df / | tail -1 | awk '{print $4}')
    local root_avail_mb=$((root_avail_kb / 1024))
    local root_avail_gb=$(echo "scale=1; $root_avail_mb / 1024" | bc 2>/dev/null || echo "?")

    log "    Available: ${root_avail_mb} MB (${root_avail_gb} GB)"

    if [ "$root_avail_mb" -lt 5120 ]; then
        error "    Insufficient disk space: ${root_avail_mb} MB (minimum: 5 GB)"
        requirements_met=false
    elif [ "$root_avail_mb" -lt 10240 ]; then
        warn "    Low disk space: ${root_avail_mb} MB (recommended: 10+ GB)"
    else
        log "    ✓ ${root_avail_gb} GB available"
    fi

    #Check architecture
    log "  Checking architecture..."
    local arch=$(uname -m)
    log "    Architecture: $arch"
    if [[ "$arch" != "x86_64" ]]; then
        warn "    Non-x86_64 architecture detected: $arch"
        warn "    This may cause compatibility issues!"
    else
        log "    ✓ x86_64 architecture"
    fi

    #Check kernel version
    log "  Checking kernel..."
    local kernel_version=$(uname -r)
    log "    Kernel: $kernel_version"

    # Extract major.minor version
    local kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    local kernel_minor=$(echo "$kernel_version" | cut -d. -f2)

    # Check if kernel is too old (< 4.9)
    if [ "$kernel_major" -lt 4 ] || ([ "$kernel_major" -eq 4 ] && [ "$kernel_minor" -lt 9 ]); then
        warn "    Old kernel: $kernel_version (recommended: 5.10+)"
    else
        log "    ✓ Kernel $kernel_version"
    fi

    #Check internet connectivity
    log "  Checking internet connectivity..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        log "    ✓ Internet accessible"
    else
        error "    No internet connectivity!"
        error "    Required for downloading packages and FreeRDP"
        requirements_met=false
    fi

    #Check DNS resolution
    log "  Checking DNS resolution..."
    if host debian.org >/dev/null 2>&1 || nslookup debian.org >/dev/null 2>&1; then
        log "    ✓ DNS resolution working"
    else
        warn "    DNS resolution may not be working"
        warn "    This could cause package download failures"
    fi

    #Summary
    echo ""
    if [ "$requirements_met" = false ]; then
        error "╔═══════════════════════════════════════════════════╗"
        error "║  ✗ SYSTEM REQUIREMENTS NOT MET                    ║"
        error "╚═══════════════════════════════════════════════════╝"
        error ""
        error "Critical requirements are not satisfied!"
        error "Please fix the issues above before proceeding."
        error ""
        return 1
    else
        log "✓ All system requirements met"
        log "  OS: $PRETTY_NAME"
        log "  CPU: $cpu_cores cores"
        log "  RAM: ${total_ram_mb} MB"
        log "  Disk: ${root_avail_gb} GB available"
        log "  Kernel: $kernel_version"
        return 0
    fi
}

# ============================================
# SETUP TIMEZONE
# ============================================
setup_timezone() {
    log "Setting timezone to Europe/Kyiv..."
    
    # Set timezone
    timedatectl set-timezone Europe/Kyiv 2>/dev/null || {
        ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
        echo "Europe/Kyiv" > /etc/timezone
    }
    
    # Sync time
    if command -v ntpdate >/dev/null 2>&1; then
        ntpdate -u pool.ntp.org >/dev/null 2>&1 || true
    fi
    
    local current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    log "✓ Timezone set: $current_tz"
}

# ============================================
# UPDATE SYSTEM
# ============================================
update_system() {
    log "Updating package lists..."
    
    # First attempt
    if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Package lists updated"
        return 0
    fi
    
    # If failed, try to fix time issues
    warn "APT update failed, trying to fix time issues..."
    
    # Disable time validation temporarily
    cat > /etc/apt/apt.conf.d/99-no-check-valid-until << 'EOF'
Acquire::Check-Valid-Until "false";
EOF
    
    # Try again
    if apt-get update 2>&1 | tee -a "$LOG_FILE"; then
        log "✓ Package lists updated (with time validation disabled)"
        rm -f /etc/apt/apt.conf.d/99-no-check-valid-until
        return 0
    fi
    
    error "apt-get update failed even after fixes"
    return 1
}

# ============================================
# INSTALL BASE PACKAGES
# ============================================
install_base_packages() {
    log "Installing base packages..."

    export DEBIAN_FRONTEND=noninteractive

    #Install packages by category for better logging
    log "  Installing build tools..."
    local build_tools=(
        build-essential pkg-config autoconf libtool cmake git
        gcc g++ make
    )

    run_apt_update
    if apt-get install -y -qq "${build_tools[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Build tools installed (${#build_tools[@]} packages)"
    else
        error "    Failed to install build tools"
        return 1
    fi

    # Verify critical build tools
    local build_tools_ok=true
    for tool in gcc g++ make cmake pkg-config; do
        if ! command -v $tool >/dev/null 2>&1; then
            error "      ✗ $tool not found"
            build_tools_ok=false
        fi
    done

    if [ "$build_tools_ok" = false ]; then
        error "    Some build tools missing!"
        return 1
    fi

    # Show versions
    log "      gcc: $(gcc --version | head -1 | awk '{print $NF}')"
    log "      cmake: $(cmake --version | head -1 | awk '{print $NF}')"

    #Web & Network packages
    log "  Installing web & network tools..."
    local network_packages=(
        nginx python3 python3-pip python3-venv tftpd-hpa tftp
        wget curl dnsutils iproute2 iputils-ping net-tools rdate
        ca-certificates gnupg libbpf1
    )

    if apt-get install -y -qq "${network_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Network tools installed (${#network_packages[@]} packages)"
    else
        error "    Failed to install network tools"
        return 1
    fi

    # Verify critical network tools
    for tool in wget curl python3 pip3; do
        if ! command -v $tool >/dev/null 2>&1; then
            error "      ✗ $tool not found"
            return 1
        fi
    done

    # Special check for nginx (may be in /usr/sbin)
    if ! command -v nginx >/dev/null 2>&1 && ! [ -x /usr/sbin/nginx ]; then
        error "      ✗ nginx not found"
        return 1
    fi

    # Show Python version
    local python_ver=$(python3 --version 2>&1 | awk '{print $2}')
    log "      Python: $python_ver"

    # Check Python version (need 3.9+)
    local python_major=$(echo "$python_ver" | cut -d. -f1)
    local python_minor=$(echo "$python_ver" | cut -d. -f2)

    if [ "$python_major" -lt 3 ] || ([ "$python_major" -eq 3 ] && [ "$python_minor" -lt 9 ]); then
        warn "      Python $python_ver is old (recommended: 3.9+)"
    else
        log "      ✓ Python $python_ver (compatible)"
    fi

    #System tools
    log "  Installing system tools..."

    # Add compression tool based on selection (default: zstd)
    local compression_pkg="${COMPRESSION_PKG:-zstd}"
    log "    Compression package: $compression_pkg"

    local system_tools=(
        sqlite3 squashfs-tools kmod udev binutils ntpdate
        file bc rsync vim-tiny vim htop busybox-static
        cron logrotate dropbear-bin openssh-client
        "$compression_pkg"
    )

    if apt-get install -y -qq "${system_tools[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ System tools installed (${#system_tools[@]} packages)"
    else
        error "    Failed to install system tools"
        return 1
    fi

    # Verify compression tool is available
    local comp_algo="${COMPRESSION_ALGO:-zstd}"
    local comp_binary=""
    case "$comp_algo" in
        pigz) comp_binary="pigz" ;;
        zstd*) comp_binary="zstd" ;;
        lz4) comp_binary="lz4" ;;
        *) comp_binary="zstd" ;;
    esac

    if command -v "$comp_binary" >/dev/null 2>&1; then
        local comp_ver=$($comp_binary --version 2>&1 | head -1 | awk '{print $NF}')
        log "      Compression: $comp_binary $comp_ver"
    else
        error "      ✗ Compression tool not found: $comp_binary"
        error "      Package installed: $compression_pkg"
        error "      This may cause initramfs build to fail!"
    fi

    # Verify SQLite version
    if command -v sqlite3 >/dev/null 2>&1; then
        local sqlite_ver=$(sqlite3 --version | awk '{print $1}')
        log "      SQLite: $sqlite_ver"
    fi

    #X.org server
    log "  Installing X.org server..."
    # Install only required video drivers (not -all metapackage)
    # Supported variants: Universal (modesetting), VMware, Intel
    local xorg_packages=(
        xorg xserver-xorg-core
        xserver-xorg-video-modesetting  # Universal fallback driver (KMS)
        xserver-xorg-video-vesa          # Legacy VESA driver
        xserver-xorg-video-fbdev         # Framebuffer driver
        xserver-xorg-video-vmware        # VMware driver
        xserver-xorg-video-intel         # Intel driver (optional, modesetting often better)
        xserver-xorg-input-all           # All input drivers
        xserver-xorg-input-evdev         # Event device input
        xserver-xorg-input-libinput      # Modern input driver
        openbox x11-utils xinit xterm
    )

    if apt-get install -y -qq "${xorg_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ X.org server installed (${#xorg_packages[@]} packages)"
    else
        error "    Failed to install X.org server"
        return 1
    fi

    # ============================================
    # X.ORG PACKAGE INTEGRITY VERIFICATION
    # ============================================
    log "    Verifying X.org package integrity..."

    verify_xorg_packages() {
        local critical_packages=(
            "xserver-xorg-core"
            "xserver-xorg-video-vesa"
        )

        local optional_packages=(
            "xserver-xorg-video-vmware"
            "xserver-xorg-video-intel"
        )

        local all_ok=true

        # Verify critical packages
        for pkg in "${critical_packages[@]}"; do
            if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                error "      ✗ CRITICAL package not installed: $pkg"
                all_ok=false
                continue
            fi

            # Verify package files integrity
            local verify_output=$(dpkg --verify "$pkg" 2>&1)
            if [ -n "$verify_output" ]; then
                error "      ✗ Package verification failed: $pkg"
                echo "$verify_output" | head -5 | while read line; do
                    error "        $line"
                done
                all_ok=false
            else
                log "      ✓ $pkg (verified)"
            fi
        done

        # Verify modesetting driver (built into xserver-xorg-core in Debian 12)
        if [ -f "/usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
            log "      ✓ modesetting_drv.so (built-in driver)"
        else
            error "      ✗ modesetting_drv.so MISSING (CRITICAL!)"
            all_ok=false
        fi

        # Verify optional packages (warnings only)
        for pkg in "${optional_packages[@]}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                local verify_output=$(dpkg --verify "$pkg" 2>&1)
                if [ -n "$verify_output" ]; then
                    warn "      ⚠ Package verification warning: $pkg"
                else
                    log "      ✓ $pkg (verified)"
                fi
            else
                warn "      ! Optional package not installed: $pkg"
            fi
        done

        if [ "$all_ok" = false ]; then
            error "    ✗ Critical X.org package verification FAILED!"
            return 1
        fi

        log "    ✓ X.org package integrity verified"
        return 0
    }

    if ! verify_xorg_packages; then
        error "X.org package verification failed - installation cannot continue"
        return 1
    fi

    # Verify X.org installation
    if [ -f "/usr/bin/Xorg" ]; then
        local xorg_ver=$(Xorg -version 2>&1 | grep "X.Org X Server" | awk '{print $4}')
        log "      ✓ X.org binary: $xorg_ver"
    else
        error "      ✗ Xorg binary not found"
        return 1
    fi

    #Verify X.org video drivers
    log "    Verifying X.org video drivers..."
    local xorg_driver_count=0

    # Universal variant (modesetting - KMS)
    if [ -f "/usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
        log "      ✓ modesetting_drv.so (Universal variant, KMS)"
        xorg_driver_count=$((xorg_driver_count + 1))
    else
        error "      ✗ modesetting_drv.so MISSING - Universal variant will fail!"
    fi

    # Legacy VESA fallback
    if [ -f "/usr/lib/xorg/modules/drivers/vesa_drv.so" ]; then
        log "      ✓ vesa_drv.so (legacy VESA fallback)"
        xorg_driver_count=$((xorg_driver_count + 1))
    else
        warn "      ! vesa_drv.so missing (legacy fallback unavailable)"
    fi

    # VMware variant
    if [ -f "/usr/lib/xorg/modules/drivers/vmware_drv.so" ]; then
        log "      ✓ vmware_drv.so (VMware variant)"
        xorg_driver_count=$((xorg_driver_count + 1))
    else
        warn "      ! vmware_drv.so missing - VMware variant will fail!"
    fi

    # Intel variant
    if [ -f "/usr/lib/xorg/modules/drivers/intel_drv.so" ]; then
        log "      ✓ intel_drv.so (Intel variant)"
        xorg_driver_count=$((xorg_driver_count + 1))
    else
        warn "      ! intel_drv.so missing - Intel variant will use modesetting"
    fi

    if [ $xorg_driver_count -ge 2 ]; then
        log "    ✓ X.org video drivers verified ($xorg_driver_count drivers found)"
    else
        error "    ✗ Insufficient X.org video drivers - variants will fail!"
    fi

    #Verify X.org input drivers
    log "    Verifying X.org input drivers..."
    local input_driver_count=0

    if [ -f "/usr/lib/xorg/modules/input/libinput_drv.so" ]; then
        log "      ✓ libinput_drv.so (modern input driver)"
        input_driver_count=$((input_driver_count + 1))
    else
        error "      ✗ libinput_drv.so MISSING - input will fail!"
    fi

    if [ -f "/usr/lib/xorg/modules/input/evdev_drv.so" ]; then
        log "      ✓ evdev_drv.so (legacy input driver)"
        input_driver_count=$((input_driver_count + 1))
    else
        warn "      ! evdev_drv.so missing (legacy fallback unavailable)"
    fi

    if [ $input_driver_count -gt 0 ]; then
        log "    ✓ X.org input drivers verified ($input_driver_count drivers found)"
    else
        error "    ✗ No X.org input drivers - mouse/keyboard will NOT work!"
    fi

    #Mesa/OpenGL + DRM libraries
    log "  Installing Mesa/OpenGL + DRM libraries..."
    local mesa_packages=(
        mesa-utils libgl1-mesa-dri libglx-mesa0 libglu1-mesa
        libgl1-mesa-glx
        libdrm2                  # Base DRM library (REQUIRED for all GPU drivers)
        libdrm-amdgpu1           # AMD amdgpu DRM library (REQUIRED for AMD Ryzen APU)
        libdrm-radeon1           # AMD radeon DRM library (REQUIRED for legacy AMD)
        libdrm-intel1            # Intel DRM library (REQUIRED for Intel variant)
    )

    if apt-get install -y -qq "${mesa_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Mesa/OpenGL + DRM libraries installed (${#mesa_packages[@]} packages)"

        #Verify libdrm libraries
        local drm_ok=true
        if [ -f "/usr/lib/x86_64-linux-gnu/libdrm.so.2" ]; then
            log "      ✓ libdrm2 (base DRM library)"
        else
            warn "      ! libdrm2 missing"
            drm_ok=false
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1" ]; then
            log "      ✓ libdrm-amdgpu1 (AMD Ryzen APU support)"
        else
            warn "      ! libdrm-amdgpu1 missing - AMD variant will fail!"
            drm_ok=false
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/libdrm_radeon.so.1" ]; then
            log "      ✓ libdrm-radeon1 (legacy AMD support)"
        else
            warn "      ! libdrm-radeon1 missing - legacy AMD will fail!"
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/libdrm_intel.so.1" ]; then
            log "      ✓ libdrm-intel1 (Intel support)"
        else
            warn "      ! libdrm-intel1 missing - Intel variant may fail!"
        fi

        if [ "$drm_ok" = true ]; then
            log "    ✓ All critical DRM libraries verified"
        else
            error "    ✗ Critical DRM libraries missing - GPU variants will fail!"
        fi

        #Verify Mesa DRI drivers
        log "    Verifying Mesa DRI drivers..."
        local dri_count=0

        # Universal fallback (software rendering)
        if [ -f "/usr/lib/x86_64-linux-gnu/dri/swrast_dri.so" ]; then
            log "      ✓ swrast_dri.so (software rendering for Universal variant)"
            dri_count=$((dri_count + 1))
        else
            warn "      ! swrast_dri.so missing - Universal variant may fail!"
        fi

        # AMD DRI drivers
        if [ -f "/usr/lib/x86_64-linux-gnu/dri/radeonsi_dri.so" ]; then
            log "      ✓ radeonsi_dri.so (AMD Ryzen APU, Vega, GCN)"
            dri_count=$((dri_count + 1))
        else
            warn "      ! radeonsi_dri.so missing - AMD Ryzen APU will fail!"
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/dri/r600_dri.so" ]; then
            log "      ✓ r600_dri.so (AMD HD 2000-7000)"
            dri_count=$((dri_count + 1))
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/dri/r300_dri.so" ]; then
            log "      ✓ r300_dri.so (legacy AMD)"
            dri_count=$((dri_count + 1))
        fi

        # Intel DRI drivers
        if [ -f "/usr/lib/x86_64-linux-gnu/dri/i965_dri.so" ]; then
            log "      ✓ i965_dri.so (Intel Gen 4-9)"
            dri_count=$((dri_count + 1))
        fi

        if [ -f "/usr/lib/x86_64-linux-gnu/dri/iris_dri.so" ]; then
            log "      ✓ iris_dri.so (Intel Gen 8+)"
            dri_count=$((dri_count + 1))
        fi

        # VMware DRI driver
        if [ -f "/usr/lib/x86_64-linux-gnu/dri/vmwgfx_dri.so" ]; then
            log "      ✓ vmwgfx_dri.so (VMware ESXi/Workstation)"
            dri_count=$((dri_count + 1))
        else
            warn "      ! vmwgfx_dri.so missing - VMware variant may fail!"
        fi

        if [ $dri_count -gt 0 ]; then
            log "    ✓ Mesa DRI drivers verified ($dri_count drivers found)"
        else
            error "    ✗ No Mesa DRI drivers found - all GPU variants will fail!"
        fi
    else
        warn "    Mesa/DRM installation had warnings (non-critical)"
    fi

    #GPU Firmware (REQUIRED for Intel and AMD variants)
    # 5 variants: Universal, VMware, Intel, AMD, Autodetect
    # Intel: i915 firmware for Intel HD/Iris Graphics
    # AMD: amdgpu/radeon firmware for AMD Ryzen APU (Radeon Vega/Graphics)
    log "  Installing GPU firmware..."
    log "    ⚠ GPU firmware required for Intel and AMD graphics"
    log "    Without firmware: Intel/AMD thin clients will show BLACK SCREEN!"

    local firmware_packages=(
        firmware-linux              # Base Linux firmware (network cards, etc.)
        firmware-linux-nonfree      # Non-free firmware (Intel i915, AMD)
        firmware-misc-nonfree       # Misc non-free firmware
        firmware-amd-graphics       # AMD GPU firmware (amdgpu, radeon) for AMD Ryzen APU
    )

    if apt-get install -y -qq "${firmware_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Firmware packages installed (${#firmware_packages[@]} packages)"

        # ============================================
        # FIRMWARE INTEGRITY VERIFICATION
        # ============================================
        log "    Verifying firmware integrity..."

        verify_firmware_integrity() {
            local firmware_dir="$1"
            local firmware_name="$2"
            local expected_min_files="$3"
            local expected_min_size_mb="$4"

            if [ ! -d "$firmware_dir" ]; then
                error "      ✗ Firmware directory missing: $firmware_dir"
                return 1
            fi

            # Count files
            local file_count=$(find "$firmware_dir" -type f 2>/dev/null | wc -l)
            if [ "$file_count" -lt "$expected_min_files" ]; then
                error "      ✗ Insufficient $firmware_name firmware files"
                error "        Found: $file_count files, Expected minimum: $expected_min_files"
                return 1
            fi

            # Check total size
            local total_size_kb=$(du -sk "$firmware_dir" 2>/dev/null | awk '{print $1}')
            local total_size_mb=$((total_size_kb / 1024))
            if [ "$total_size_mb" -lt "$expected_min_size_mb" ]; then
                error "      ✗ $firmware_name firmware directory too small"
                error "        Size: ${total_size_mb}MB, Expected minimum: ${expected_min_size_mb}MB"
                return 1
            fi

            # Verify no empty files (corrupted)
            local empty_count=$(find "$firmware_dir" -type f -size 0 2>/dev/null | wc -l)
            if [ "$empty_count" -gt 0 ]; then
                error "      ✗ Found $empty_count empty (corrupted) firmware files in $firmware_dir"
                find "$firmware_dir" -type f -size 0 2>/dev/null | head -5 | while read f; do
                    error "        - $f"
                done
                return 1
            fi

            log "      ✓ $firmware_name firmware: $file_count files, ${total_size_mb}MB (verified)"
            return 0
        }

        #Verify Intel i915 firmware
        # Note: Debian 12 firmware-linux-nonfree (20230210-5) has ~115 files, ~15MB
        # Newer versions have 500+ files, 40+ MB
        local fw_ok=true
        if ! verify_firmware_integrity "/lib/firmware/i915" "Intel i915" 100 10; then
            error "      ⚠ CRITICAL: Intel thin clients will show BLACK SCREEN!"
            fw_ok=false
        fi

        #Verify AMD amdgpu firmware (for AMD Ryzen APU)
        # Note: Debian 12 firmware-amd-graphics (20230210-5) has ~530 files, ~60MB
        # Newer versions have 1000+ files, 150+ MB
        if ! verify_firmware_integrity "/lib/firmware/amdgpu" "AMD amdgpu" 500 50; then
            error "      ⚠ CRITICAL: AMD Ryzen APU thin clients will show BLACK SCREEN!"
            fw_ok=false
        fi

        #Verify AMD radeon firmware (legacy AMD)
        # Note: Debian 12 has ~100 files, ~7MB
        if [ -d "/lib/firmware/radeon" ]; then
            if ! verify_firmware_integrity "/lib/firmware/radeon" "AMD radeon" 90 5; then
                warn "      ⚠ WARNING: Legacy AMD thin clients may not work!"
            else
                log "      ✓ AMD radeon firmware verified (legacy AMD support)"
            fi
        else
            warn "      ! AMD radeon firmware NOT FOUND (legacy AMD will not work)"
        fi

        if [ "$fw_ok" = true ]; then
            log "    ✓ All critical GPU firmware verified and ready"
        else
            error "    ✗ FIRMWARE VERIFICATION FAILED!"
            error "    Affected thin clients will show BLACK SCREEN!"
            error "    This is a CRITICAL issue - installation cannot continue."
            return 1
        fi
    else
        error "    Failed to install GPU firmware packages"
        error "    ⚠ CRITICAL: Intel thin clients will NOT work without firmware!"
        return 1
    fi

    #Additional services
    log "  Installing additional services..."
    local service_packages=(
        p910nd              # Print server
        alsa-utils          # ALSA CLI tools
        pulseaudio          # PulseAudio sound server (required for FreeRDP audio)
        pulseaudio-utils    # PulseAudio utilities (pactl, pacmd)
    )

    if apt-get install -y -qq "${service_packages[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Additional services installed (${#service_packages[@]} packages)"
    else
        warn "    Some services failed to install (non-critical)"
    fi

    #Configure and enable Nginx
    log "  Configuring services..."
    systemctl unmask nginx 2>/dev/null || true

    if systemctl enable nginx 2>&1 | tee -a "$LOG_FILE"; then
        log "    ✓ Nginx enabled"
    else
        error "    Failed to enable Nginx"
        return 1
    fi

    # Don't start Nginx yet (will be configured later)
    systemctl stop nginx 2>/dev/null || true

    #Summary
    local total_packages=$((${#build_tools[@]} + ${#network_packages[@]} + ${#system_tools[@]} + ${#xorg_packages[@]} + ${#mesa_packages[@]} + ${#service_packages[@]}))

    log "✓ Base packages installed successfully"
    log "  Total: $total_packages packages"
    log "  Build tools: ${#build_tools[@]}"
    log "  Network: ${#network_packages[@]}"
    log "  System: ${#system_tools[@]}"
    log "  X.org: ${#xorg_packages[@]}"
    log "  Mesa/OpenGL: ${#mesa_packages[@]}"
    log "  Services: ${#service_packages[@]}"

    return 0
}

# ============================================
# INSTALL FREERDP DEPENDENCIES
# ============================================
install_freerdp_deps() {
    log "Installing FreeRDP 3.x dependencies..."

    local deps=(
        # Core build tools
        build-essential cmake pkg-config libssl-dev
        
        # X11
        libx11-dev libxext-dev libxinerama-dev libxcursor-dev
        libxdamage-dev libxv-dev libxkbfile-dev libxi-dev
        libxrandr-dev libxfixes-dev libxrender-dev libxcb1-dev
        
        # Audio
        libasound2-dev libpulse-dev libgstreamer1.0-dev
        libgstreamer-plugins-base1.0-dev
        
        # Video
        libavutil-dev libavcodec-dev libswscale-dev libswresample-dev
        
        # Other
        libcups2-dev libxml2-dev libusb-1.0-0-dev libudev-dev
        libdbus-glib-1-dev libglib2.0-dev libkrb5-dev
        libcjson-dev liburiparser-dev libsystemd-dev
        libpcsclite-dev libjpeg-dev libfuse3-dev
        libgtk-3-dev
    )
    
    apt-get install -y -qq "${deps[@]}" 2>&1 | tee -a "$LOG_FILE" || {
        warn "Some FreeRDP dependencies failed, continuing..."
    }
    
    log "✓ FreeRDP dependencies installed"
}

# ============================================
# COMPILE FREERDP 3.17.2
# ============================================
compile_freerdp() {
    local version="3.17.2"
    local url="https://github.com/FreeRDP/FreeRDP/archive/refs/tags/${version}.tar.gz"
    local build_dir="/tmp/freerdp-build-$$"
    
    log "Compiling FreeRDP v$version..."
    log "  This will take 5-10 minutes..."
    
    # Check if already installed
    if [ -f "/usr/local/bin/xfreerdp" ]; then
        local installed_ver=$(/usr/local/bin/xfreerdp --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1 || echo "")
        if [[ "$installed_ver" == "$version" ]]; then
            log "✓ FreeRDP $version already installed"
            return 0
        else
            log "  Found v$installed_ver, upgrading to v$version..."
        fi
    fi
    
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    
    #Download source with validation
    log "  Downloading source from GitHub..."
    log "    URL: $url"

    if ! wget -q --timeout=60 --tries=3 "$url" -O freerdp.tar.gz 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to download FreeRDP source"
        error "  Check internet connectivity"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    # Verify download
    local download_size=$(stat -c%s freerdp.tar.gz 2>/dev/null || stat -f%z freerdp.tar.gz 2>/dev/null || echo "0")
    local download_size_mb=$((download_size / 1024 / 1024))

    if [ "$download_size" -lt 1000000 ]; then
        error "Downloaded file too small: $download_size bytes"
        error "  Download may be incomplete or corrupted"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    log "    Downloaded: ${download_size_mb} MB"

    #Extract with validation
    log "  Extracting source..."
    if ! tar xzf freerdp.tar.gz 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to extract FreeRDP source"
        error "  Archive may be corrupted"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    if [ ! -d "FreeRDP-${version}" ]; then
        error "Extracted directory not found: FreeRDP-${version}"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    cd "FreeRDP-${version}"
    log "    ✓ Source extracted"

    # Count source files
    local source_files=$(find . -name "*.c" -o -name "*.h" | wc -l)
    log "    Source files: $source_files"

    mkdir -p build
    cd build

    #Verify OpenSSL is available
    log "  Checking dependencies..."
    if ! pkg-config --exists openssl; then
        error "OpenSSL not found! Installing libssl-dev..."
        apt-get install -y libssl-dev pkg-config
    fi

    local openssl_version=$(pkg-config --modversion openssl 2>/dev/null || echo "unknown")
    log "    OpenSSL: $openssl_version"
    log "    OpenSSL path: $(pkg-config --variable=prefix openssl || echo 'not found')"

    #Configure with detailed options
    log "  Configuring build (CMake)..."
    log "    Build type: Release"
    log "    Prefix: /usr/local"
    log "    Features: X11, CUPS, Pulse, FFmpeg, GStreamer, Smartcard, USB"

    local cmake_log="$build_dir/cmake_output.log"

    if ! cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DOPENSSL_ROOT_DIR=/usr \
        -DBUILD_SHARED_LIBS=ON \
        -DWITH_CHANNELS=ON \
        -DBUILTIN_CHANNELS=OFF \
        -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_WAYLAND=OFF \
        -DWITH_X11=ON \
        -DWITH_CUPS=ON \
        -DWITH_PULSE=ON \
        -DWITH_ALSA=ON \
        -DWITH_FFMPEG=ON \
        -DWITH_GSTREAMER_1_0=ON \
        -DWITH_SSE2=ON \
        -DWITH_SERVER=OFF \
        -DWITH_PCSC=ON \
        -DWITH_JPEG=ON \
        -DWITH_SMARTCARD=ON \
        -DCHANNEL_URBDRC=ON \
        -DCHANNEL_URBDRC_CLIENT=ON \
        -DCHANNEL_PRINTER=ON \
        -DCHANNEL_CLIPRDR=ON \
        -DCHANNEL_DRIVE=ON \
        -DWITH_INTERNAL_RC4=ON \
        -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_MD5=ON \
        .. 2>&1 | tee "$cmake_log" | grep -v "Warning"; then
        error "CMake configuration failed"
        error "  Check log: $cmake_log"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    log "    ✓ CMake configuration complete"

    #Build with progress
    local cpu_count=$(nproc)
    log "  Building FreeRDP..."
    log "    Using $cpu_count parallel jobs"
    log "    This will take 5-10 minutes depending on CPU speed..."

    local build_start=$(date +%s)
    local build_log="$build_dir/build_output.log"

    if ! make -j$cpu_count 2>&1 | tee "$build_log" | grep -v "warning:"; then
        error "Compilation failed"
        error "  Check log: $build_log"

        # Show last errors
        error "  Last errors:"
        grep -i "error" "$build_log" | tail -5 | while read line; do
            error "    $line"
        done

        cd /
        rm -rf "$build_dir"
        return 1
    fi

    local build_end=$(date +%s)
    local build_duration=$((build_end - build_start))
    local build_minutes=$((build_duration / 60))
    local build_seconds=$((build_duration % 60))

    log "    ✓ Build complete in ${build_minutes}m ${build_seconds}s"

    #Install
    log "  Installing FreeRDP..."
    local install_log="$build_dir/install_output.log"

    if ! make install 2>&1 | tee "$install_log"; then
        error "Installation failed"
        error "  Check log: $install_log"
        cd /
        rm -rf "$build_dir"
        return 1
    fi

    log "    ✓ Files installed to /usr/local"

    # Update library cache
    log "  Updating library cache..."
    if command -v ldconfig >/dev/null 2>&1; then
        ldconfig
    elif [ -x /usr/sbin/ldconfig ]; then
        /usr/sbin/ldconfig
    elif [ -x /sbin/ldconfig ]; then
        /sbin/ldconfig
    else
        warn "  ldconfig not found, skipping library cache update"
    fi

    cd /
    rm -rf "$build_dir"

    #CRITICAL: Verify installation
    log "  Verifying FreeRDP installation..."

    if [ ! -f "/usr/local/bin/xfreerdp" ]; then
        error "    ✗ xfreerdp binary not found at /usr/local/bin/xfreerdp"
        return 1
    fi
    log "    ✓ Binary exists: /usr/local/bin/xfreerdp"

    # Make executable
    chmod +x /usr/local/bin/xfreerdp

    #Test execution
    log "  Testing FreeRDP..."
    if ! /usr/local/bin/xfreerdp --version >/dev/null 2>&1; then
        error "    ✗ xfreerdp cannot execute"
        error "    Try manually: /usr/local/bin/xfreerdp --version"
        return 1
    fi
    log "    ✓ Binary executes successfully"

    #Verify version
    local final_version=$(/usr/local/bin/xfreerdp --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1 || echo "unknown")

    if [ "$final_version" != "$version" ]; then
        warn "    Version mismatch: expected $version, got $final_version"
    else
        log "    ✓ Version: $final_version (correct)"
    fi

    #Check library dependencies
    log "  Checking library dependencies..."
    local missing_libs=$(ldd /usr/local/bin/xfreerdp 2>/dev/null | grep "not found" | wc -l)

    if [ "$missing_libs" -gt 0 ]; then
        error "    ✗ Missing library dependencies:"
        ldd /usr/local/bin/xfreerdp 2>/dev/null | grep "not found"
        return 1
    fi
    log "    ✓ All library dependencies satisfied"

    #Test help output
    if /usr/local/bin/xfreerdp --help 2>&1 | grep -q "FreeRDP"; then
        log "    ✓ Help output working"
    else
        warn "    Help output may have issues"
    fi

    log "✓ FreeRDP v$final_version installed and verified"
    log "  Build time: ${build_minutes}m ${build_seconds}s"
    log "  Installed to: /usr/local/bin/xfreerdp"
    log "  Library dependencies: OK"

    return 0
}

# ============================================
# CREATE DIRECTORIES
# ============================================
create_directories() {
    log "Creating directory structure..."
    
    ensure_dir "$TFTP_ROOT/efi64" 755
    ensure_dir "$WEB_ROOT/boot" 755
    ensure_dir "$WEB_ROOT/kernels" 755
    ensure_dir "$WEB_ROOT/initrds" 755
    ensure_dir "$WEB_ROOT/drivers" 755
    ensure_dir "$APP_DIR/templates" 755
    ensure_dir "$APP_DIR/db" 755
    ensure_dir "$LOG_DIR" 755
    
    touch "$LOG_DIR/app.log" "$LOG_DIR/server.log"
    chmod 644 "$LOG_DIR"/*.log
    
    log "✓ Directory structure created"
}

# ============================================
# VERIFY INSTALLATION
# ============================================
verify_installation() {
    log "Verifying core system installation..."

    local ok=true

    # Check FreeRDP
    if [ -f "/usr/local/bin/xfreerdp" ]; then
        if /usr/local/bin/xfreerdp --version >/dev/null 2>&1; then
            local ver=$(/usr/local/bin/xfreerdp --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1)
            log "  ✓ FreeRDP v$ver"
        else
            error "  ✗ FreeRDP (cannot execute)"
            ok=false
        fi
    else
        error "  ✗ FreeRDP (not found)"
        ok=false
    fi

    # Check GPU firmware
    # 5 variants: Universal, VMware, Intel, AMD, Autodetect
    # Intel/AMD variants require GPU firmware
    log "  Checking GPU firmware..."
    local fw_count=0

    # Intel i915 firmware (REQUIRED for Intel variant)
    if [ -d "/lib/firmware/i915" ]; then
        local i915_count=$(find /lib/firmware/i915 -type f 2>/dev/null | wc -l)
        log "    ✓ Intel i915 firmware ($i915_count files)"
        fw_count=$((fw_count + 1))
    else
        warn "    ! Intel i915 firmware missing"
    fi

    # AMD amdgpu firmware (REQUIRED for AMD Ryzen APU variant)
    if [ -d "/lib/firmware/amdgpu" ]; then
        local amdgpu_count=$(find /lib/firmware/amdgpu -type f 2>/dev/null | wc -l)
        log "    ✓ AMD amdgpu firmware ($amdgpu_count files)"
        fw_count=$((fw_count + 1))
    else
        warn "    ! AMD amdgpu firmware missing"
    fi

    # AMD radeon firmware (legacy AMD)
    if [ -d "/lib/firmware/radeon" ]; then
        local radeon_count=$(find /lib/firmware/radeon -type f 2>/dev/null | wc -l)
        log "    ✓ AMD radeon firmware ($radeon_count files)"
        fw_count=$((fw_count + 1))
    else
        warn "    ! AMD radeon firmware missing"
    fi

    if [ $fw_count -eq 3 ]; then
        log "  ✓ All GPU firmware installed ($fw_count/3)"
    elif [ $fw_count -gt 0 ]; then
        warn "  ⚠ Partial GPU firmware ($fw_count/3) - some thin clients may not work"
    else
        error "  ✗ No GPU firmware installed - Intel/AMD thin clients will fail!"
    fi

    # Check directories
    for dir in "$TFTP_ROOT" "$WEB_ROOT" "$APP_DIR" "$LOG_DIR"; do
        if [ -d "$dir" ]; then
            log "  ✓ $dir"
        else
            error "  ✗ $dir"
            ok=false
        fi
    done

    if [ "$ok" = true ]; then
        log "✓ Core system verification passed"
        return 0
    else
        error "✗ Core system verification failed"
        return 1
    fi
}

# ============================================
# MAIN
# ============================================
main() {
    #CRITICAL: Validate system requirements first
    log ""
    if ! validate_system_requirements; then
        exit 1
    fi

    log ""
    setup_timezone || exit 1

    log ""
    fix_apt_sources || exit 1

    log ""
    update_system || exit 1

    log ""
    install_base_packages || exit 1

    log ""
    install_freerdp_deps || exit 1

    log ""
    # CRITICAL STEP: Compile FreeRDP
    if ! compile_freerdp; then
        error ""
        error "╔═══════════════════════════════════════════════════╗"
        error "║  ✗ FREERDP COMPILATION FAILED                     ║"
        error "╚═══════════════════════════════════════════════════╝"
        error ""
        error "Core system installation cannot continue without FreeRDP!"
        error ""
        error "Common issues:"
        error "  - Insufficient RAM (need 1GB+)"
        error "  - Insufficient disk space (need 5GB+)"
        error "  - Missing build dependencies"
        error "  - Network issues during download"
        error ""
        error "Check logs above for specific errors."
        exit 1
    fi

    log ""
    create_directories || exit 1

    log ""
    # Verify installation
    if verify_installation; then
        log ""
        log "╔═══════════════════════════════════════════════════╗"
        log "║  ✓ CORE SYSTEM INSTALLED v$MODULE_VERSION        ║"
        log "╚═══════════════════════════════════════════════════╝"
        log ""
        log "✓ All components verified"
        log "✓ FreeRDP 3.17.2 compiled and tested"
        log "✓ All dependencies satisfied"
        log "✓ Directories created"
        log ""
        exit 0
    else
        error "✗ Core system verification failed"
        exit 1
    fi
}

main "$@"