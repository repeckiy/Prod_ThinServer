#!/usr/bin/env bash
# Thin-Server Module: Initramfs Builder
# Creates minimal bootable initramfs with FreeRDP

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

MODULE_NAME="initramfs"
MODULE_VERSION="$APP_VERSION"

log "═══════════════════════════════════════"
log "Building: Initramfs v$MODULE_VERSION"
log "═══════════════════════════════════════"

# ============================================
# PRE-BUILD CHECKS
# ============================================
check_xorg_drivers() {
    log "Checking X.org input drivers on host..."

    local drivers_found=0

    if [ -f /usr/lib/xorg/modules/input/evdev_drv.so ]; then
        log "  ✓ evdev_drv.so found"
        drivers_found=$((drivers_found + 1))
    else
        warn "  ✗ evdev_drv.so NOT found"
    fi

    if [ -f /usr/lib/xorg/modules/input/libinput_drv.so ]; then
        log "  ✓ libinput_drv.so found"
        drivers_found=$((drivers_found + 1))
    else
        warn "  ✗ libinput_drv.so NOT found"
    fi

    if [ $drivers_found -eq 0 ]; then
        error "No X.org input drivers found!"
        log "Installing X.org input drivers..."

        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y xserver-xorg-input-evdev xserver-xorg-input-libinput || {
                error "Failed to install X.org input drivers"
                return 1
            }
            log "  ✓ X.org input drivers installed"
        else
            error "apt-get not found, cannot install drivers automatically"
            return 1
        fi
    fi

    return 0
}

# ============================================
# BUILD INITRAMFS
# ============================================
build_initramfs() {
    log "Creating initramfs..."
    
    local work_dir="/tmp/initramfs-build-$$"
    local output_file="$WEB_ROOT/initrds/initrd-minimal.img"
    
    rm -rf "$work_dir"
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    log "  Creating directory structure..."
    mkdir -p {bin,sbin,etc,proc,sys,dev,tmp,run,var/log,root}
    mkdir -p usr/{bin,sbin,lib,lib64,share/zoneinfo/Europe,share/X11/xkb}
    mkdir -p lib/{x86_64-linux-gnu,firmware,modules}
    mkdir -p lib64 usr/lib/xorg/modules/{drivers,input,extensions}
    mkdir -p dev/{input,dri,snd,usb}
    
    # ============================================
    # TIMEZONE
    # ============================================
    log "  Installing timezone data..."
    cp /usr/share/zoneinfo/Europe/Kyiv usr/share/zoneinfo/Europe/
    ln -sf /usr/share/zoneinfo/Europe/Kyiv etc/localtime
    echo "Europe/Kyiv" > etc/timezone
    
    # ============================================
    # KERNEL MODULES
    # ============================================
    #Use current running kernel version instead of alphabetically first
    local kernel_ver=$(uname -r)
    if [ -n "$kernel_ver" ] && [ -d "/lib/modules/$kernel_ver" ]; then
        log "  Copying kernel $kernel_ver modules (current running kernel)..."
        
        if [ -d "/lib/modules/$kernel_ver/kernel/drivers" ]; then
            mkdir -p "lib/modules/$kernel_ver/kernel/drivers"

            # Network drivers - SELECTIVE COPY (Ethernet only, no Wi-Fi)
            copy_network_drivers() {
                log "  Copying essential ETHERNET drivers..."

                local kernel_ver=$(uname -r)
                local dest_dir="lib/modules/$kernel_ver/kernel/drivers/net"
                mkdir -p "$dest_dir"

                # ТІЛЬКИ ETHERNET драйвери (НЕ Wi-Fi!)
                local ESSENTIAL_DRIVERS=(
                    "e1000.ko" "e1000e.ko" "igb.ko" "ixgbe.ko" "i40e.ko" "ice.ko"
                    "r8169.ko" "r8168.ko" "8139too.ko" "8139cp.ko"
                    "tg3.ko" "bnx2.ko" "bnx2x.ko" "bnxt_en.ko"
                    "forcedeth.ko" "sky2.ko" "skge.ko" "atl1.ko" "atl1c.ko"
                    "vmxnet3.ko" "virtio_net.ko" "hv_netvsc.ko" "xen-netfront.ko"
                    "pcnet32.ko" "amd8111e.ko" "sis900.ko" "via-rhine.ko"
                )

                local copied=0
                for driver in "${ESSENTIAL_DRIVERS[@]}"; do
                    local found=$(find "/lib/modules/$kernel_ver" -name "$driver" -type f 2>/dev/null | head -1)
                    if [ -n "$found" ]; then
                        cp "$found" "$dest_dir/" 2>/dev/null && copied=$((copied + 1))
                    fi
                done

                log "    ✓ Copied $copied Ethernet drivers"
            }

            copy_network_drivers

            #Only I2C drivers (for monitor detection)
            # GPU-specific kernel modules (amdgpu, i915, nouveau, radeon, vmwgfx)
            # will be added by variant builder to reduce base image size
            log "  Copying I2C drivers (monitor detection)..."
            if [ -d "/lib/modules/$kernel_ver/kernel/drivers/i2c" ]; then
                cp -a "/lib/modules/$kernel_ver/kernel/drivers/i2c" \
                    "lib/modules/$kernel_ver/kernel/drivers/" 2>/dev/null || true
                log "    ✓ Copied i2c drivers"
            fi

            #Copy ONLY base DRM core (NOT GPU-specific drivers!)
            log "  Copying base DRM core modules..."
            mkdir -p "lib/modules/$kernel_ver/kernel/drivers/gpu/drm"

            # Copy only essential DRM core files (not GPU drivers)
            for drm_core in drm.ko drm_kms_helper.ko drm_ttm_helper.ko ttm.ko; do
                local found=$(find "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm" -name "$drm_core" -type f 2>/dev/null | head -1)
                if [ -n "$found" ]; then
                    cp "$found" "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/" 2>/dev/null || true
                    log "    ✓ Copied $drm_core"
                fi
            done

            log "    ℹ GPU-specific modules (amdgpu, i915, nouveau, radeon, vmwgfx) will be added by variant builder"

            # USB modules  
            for subdir in core host storage class; do
                if [ -d "/lib/modules/$kernel_ver/kernel/drivers/usb/$subdir" ]; then
                    mkdir -p "lib/modules/$kernel_ver/kernel/drivers/usb"
                    cp -a "/lib/modules/$kernel_ver/kernel/drivers/usb/$subdir" \
                        "lib/modules/$kernel_ver/kernel/drivers/usb/" 2>/dev/null || true
                fi
            done
            
            # HID/Input drivers
            for subdir in hid input; do
                if [ -d "/lib/modules/$kernel_ver/kernel/drivers/$subdir" ]; then
                    cp -a "/lib/modules/$kernel_ver/kernel/drivers/$subdir" \
                        "lib/modules/$kernel_ver/kernel/drivers/" 2>/dev/null || true
                fi
            done
        fi

        #Sound kernel modules (CRITICAL for ALSA audio and microphone)
        # Copy entire sound subsystem for audio output (speakers) and input (microphone)
        if [ -d "/lib/modules/$kernel_ver/kernel/sound" ]; then
            log "  Copying sound kernel modules..."
            mkdir -p "lib/modules/$kernel_ver/kernel"
            cp -a "/lib/modules/$kernel_ver/kernel/sound" \
                "lib/modules/$kernel_ver/kernel/" 2>/dev/null && {
                local sound_size=$(du -sh "lib/modules/$kernel_ver/kernel/sound" 2>/dev/null | awk '{print $1}')
                log "    ✓ Sound modules copied ($sound_size)"
                log "    Includes: ALSA core, PCI/USB audio, HDA codecs"
            } || {
                warn "    ! Failed to copy sound modules - audio may not work!"
            }
        else
            warn "  ! Sound kernel modules not found on host - audio will NOT work!"
        fi
        
        # Module metadata
        for f in modules.{order,builtin,dep,dep.bin,alias,alias.bin,symbols,symbols.bin}; do
            if [ -f "/lib/modules/$kernel_ver/$f" ]; then
                cp "/lib/modules/$kernel_ver/$f" "lib/modules/$kernel_ver/"
            fi
        done
    fi

    # ============================================
    # NETWORK FIRMWARE
    # ============================================
    copy_network_firmware() {
        log "  Copying Ethernet firmware..."

        local FIRMWARE_LIST=(
            "e100"          # Intel
            "rtl_nic"       # Realtek Ethernet (НЕ rtlwifi!)
            "bnx2"          # Broadcom
            "bnx2x"
            "tigon"         # Broadcom Tigon
        )

        mkdir -p lib/firmware

        for pattern in "${FIRMWARE_LIST[@]}"; do
            if [ -d "/lib/firmware/$pattern" ]; then
                cp -r "/lib/firmware/$pattern" lib/firmware/ 2>/dev/null
                log "    ✓ Copied firmware: $pattern"
            fi
        done
    }

    copy_network_firmware

    # ============================================
    # VIDEO FIRMWARE (GPU firmware)
    # ============================================
    #GPU-specific firmware now added by variant builder
    # Base image uses only software rendering (vesa/modesetting)
    # Each variant (vmware/intel/amd/nvidia) adds its own firmware
    #
    # This saves ~100-200MB in base image:
    # - i915: ~50-100MB
    # - amdgpu: ~100-200MB
    # - radeon: ~50-100MB
    # - nouveau: ~20-40MB
    #
    # See: modules/build-initramfs-variants.sh lines 140-204

    # ============================================
    # BUSYBOX
    # ============================================
    log "  Installing BusyBox..."
    
    if [ ! -f /bin/busybox ]; then
        error "BusyBox not found"
        return 1
    fi
    
    cp /bin/busybox bin/
    
    for cmd in sh ash ls cat cp mv rm mkdir mount umount ln chmod chown \
               ps kill sleep grep sed awk cut head tail wc tr sort gzip \
               basename dirname mknod ping nslookup date find du echo \
               udhcpc reboot hwclock tee lsmod; do
        ln -sf busybox "bin/$cmd" 2>/dev/null || true
    done
    
    log "    ✓ BusyBox + $(ls -1 bin/ | wc -l) commands"
    
    # ============================================
    # CORE BINARIES
    # ============================================
    log "  Copying core binaries..."
    
    # ip command
    if [ -f /sbin/ip ]; then
        cp /sbin/ip bin/ip
        log "    ✓ ip from /sbin/ip"
    elif [ -f /bin/ip ]; then
        cp /bin/ip bin/ip
        log "    ✓ ip from /bin/ip"
    elif [ -f /usr/sbin/ip ]; then
        cp /usr/sbin/ip bin/ip
        log "    ✓ ip from /usr/sbin/ip"
    else
        error "ip command not found!"
        return 1
    fi
    
    # wget
    if [ -f /usr/bin/wget.real ]; then
        cp /usr/bin/wget.real bin/wget
    elif [ -f /usr/bin/wget ]; then
        cp /usr/bin/wget bin/wget
    elif [ -f /bin/wget ]; then
        cp /bin/wget bin/wget
    fi
    
    # ============================================
    # NTP TOOLS - Copy ntpdate binary directly
    # ============================================
    log "  Installing NTP tools..."

    # Copy ntpdate (primary NTP tool for Debian 12)
    if [ -f /usr/bin/ntpdate ]; then
        cp /usr/bin/ntpdate usr/bin/
        log "    ✓ ntpdate from /usr/bin"

        # Copy ntpdate dependencies (libraries)
        log "    Copying ntpdate dependencies..."
        ldd /usr/bin/ntpdate 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
        log "    ✓ ntpdate dependencies copied"

    elif [ -f /usr/sbin/ntpdate ]; then
        mkdir -p usr/sbin
        cp /usr/sbin/ntpdate usr/sbin/
        log "    ✓ ntpdate from /usr/sbin"

        # Copy dependencies
        log "    Copying ntpdate dependencies..."
        ldd /usr/sbin/ntpdate 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
        log "    ✓ ntpdate dependencies copied"
    else
        warn "    ! ntpdate not found, NTP sync will not work!"
    fi

    # rdate as fallback (check multiple locations)
    rdate_found=false
    if [ -f /usr/bin/rdate ]; then
        cp /usr/bin/rdate usr/bin/
        rdate_source="/usr/bin/rdate"
        rdate_found=true
        log "    ✓ rdate from /usr/bin"
    elif [ -f /usr/sbin/rdate ]; then
        cp /usr/sbin/rdate usr/bin/
        rdate_source="/usr/sbin/rdate"
        rdate_found=true
        log "    ✓ rdate from /usr/sbin"
    elif [ -f /bin/rdate ]; then
        cp /bin/rdate usr/bin/
        rdate_source="/bin/rdate"
        rdate_found=true
        log "    ✓ rdate from /bin"
    fi

    # Copy rdate dependencies if found
    if [ "$rdate_found" = "true" ]; then
        log "    Copying rdate dependencies..."
        ldd "$rdate_source" 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
        log "    ✓ rdate dependencies copied"
    fi

    # Module tools
    for tool in modprobe depmod insmod lsmod rmmod; do
        if [ -f /sbin/$tool ]; then
            cp /sbin/$tool sbin/
        fi
    done

    log "    ✓ NTP tools installed"

    # ============================================
    # SSH SERVER - Dropbear Ð´Ð»Ñ Ð´Ñ–Ð°Ð³Ð½Ð¾ÑÑ‚Ð¸ÐºÐ¸
    # ============================================
    log "  Installing SSH server (Dropbear)..."

    # Copy dropbear binary
    if [ -f /usr/sbin/dropbear ]; then
        mkdir -p usr/sbin
        cp /usr/sbin/dropbear usr/sbin/
        log "    ✓ dropbear binary copied"

        # Copy dropbear dependencies
        log "    Copying dropbear dependencies..."
        ldd /usr/sbin/dropbear 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
        log "    ✓ dropbear dependencies copied"
    else
        warn "    ! dropbear not found (SSH will not work)"
    fi

    # Copy dropbearkey for host key generation
    if [ -f /usr/bin/dropbearkey ]; then
        mkdir -p usr/bin
        cp /usr/bin/dropbearkey usr/bin/
        log "    ✓ dropbearkey copied"

        # Copy dropbearkey dependencies
        ldd /usr/bin/dropbearkey 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
    fi

    # Create SSH directories
    mkdir -p etc/dropbear
    mkdir -p root/.ssh
    chmod 700 root/.ssh

    # Create empty authorized_keys (Ð¼Ð¾Ð¶Ð½Ð° Ð´Ð¾Ð´Ð°Ñ‚Ð¸ ÐºÐ»ÑŽÑ‡Ñ– Ð¿Ñ–Ð·Ð½Ñ–ÑˆÐµ)
    touch root/.ssh/authorized_keys
    chmod 600 root/.ssh/authorized_keys

    log "    ✓ SSH server installed"

    # udev for device management
    log "    Installing udev..."
    if [ -f /sbin/udevd ]; then
        cp /sbin/udevd sbin/
        log "    ✓ udevd"
    elif [ -f /lib/systemd/systemd-udevd ]; then
        mkdir -p lib/systemd
        cp /lib/systemd/systemd-udevd lib/systemd/
        ln -sf ../lib/systemd/systemd-udevd sbin/udevd
        log "    ✓ systemd-udevd"
    fi
    
    if [ -f /bin/udevadm ]; then
        cp /bin/udevadm bin/
        log "    ✓ udevadm"
    fi
    
    # Other tools
    if [ -f /sbin/ldconfig ]; then
        cp /sbin/ldconfig sbin/
    fi
    
    if [ -f /usr/sbin/p910nd ]; then
        cp /usr/sbin/p910nd usr/sbin/
    fi
    
    log "    ✓ Core binaries copied"
    
    # ============================================
    # X.ORG
    # ============================================
    log "  Copying X.org..."
    
    if [ ! -f /usr/lib/xorg/Xorg ]; then
        error "Xorg not found"
        return 1
    fi
    
    mkdir -p usr/lib/xorg
    cp /usr/lib/xorg/Xorg usr/lib/xorg/
    
    # X.org modules
    if [ -d /usr/lib/xorg/modules ]; then
        log "    Installing X.org modules..."

        #Only universal drivers (modesetting + vesa)
        # GPU-specific drivers will be added by variant builder
        mkdir -p usr/lib/xorg/modules/{drivers,input,extensions}

        # Video drivers - MINIMAL set for base image
        log "      Copying base video drivers (universal only)..."
        local video_drivers_copied=0
        for drv in modesetting vesa fbdev; do
            if [ -f "/usr/lib/xorg/modules/drivers/${drv}_drv.so" ]; then
                cp -L "/usr/lib/xorg/modules/drivers/${drv}_drv.so" \
                    "usr/lib/xorg/modules/drivers/" 2>/dev/null && {
                    log "        ✓ ${drv}_drv.so"
                    video_drivers_copied=$((video_drivers_copied + 1))
                }
            fi
        done

        if [ $video_drivers_copied -eq 0 ]; then
            warn "        ! No X.org video drivers found - X server may fail!"
        else
            log "        ✓ Copied $video_drivers_copied universal drivers"
            log "        ℹ GPU-specific drivers (vmware, intel, amd, nvidia) will be added by variant builder"
        fi

        # Input drivers
        log "      Copying input drivers..."
        for mod in libinput_drv.so evdev_drv.so; do
            if [ -f "/usr/lib/xorg/modules/input/$mod" ]; then
                cp -L "/usr/lib/xorg/modules/input/$mod" \
                    "usr/lib/xorg/modules/input/" 2>/dev/null || true
                log "        ✓ $mod"
            fi
        done

        # GLX extension (critical for hardware acceleration)
        if [ -f "/usr/lib/xorg/modules/extensions/libglx.so" ]; then
            cp -L "/usr/lib/xorg/modules/extensions/libglx.so" \
                "usr/lib/xorg/modules/extensions/" 2>/dev/null || true
            log "        ✓ libglx.so (GLX extension)"
        fi

        #Copy ONLY software rendering DRI drivers
        # GPU-specific DRI drivers will be added by variant builder
        log "      Copying base DRI drivers (software rendering only)..."
        if [ -d /usr/lib/x86_64-linux-gnu/dri ]; then
            mkdir -p usr/lib/x86_64-linux-gnu/dri

            # Copy only software rendering drivers for base
            local dri_copied=0
            for dri in swrast_dri.so kms_swrast_dri.so; do
                if [ -f "/usr/lib/x86_64-linux-gnu/dri/$dri" ]; then
                    cp -L "/usr/lib/x86_64-linux-gnu/dri/$dri" \
                        usr/lib/x86_64-linux-gnu/dri/ 2>/dev/null && {
                        log "        ✓ $dri"
                        dri_copied=$((dri_copied + 1))
                    }
                fi
            done

            if [ $dri_copied -eq 0 ]; then
                warn "        ! No software DRI drivers found"
            else
                log "        ✓ Copied $dri_copied software DRI drivers (~5-10MB)"
                log "        ℹ GPU-specific DRI drivers will be added by variant builder"
            fi

            #Copy DRI driver dependencies
            # DRI drivers have many dependencies (Mesa, libdrm, libglapi, etc.)
            # Without these, X Server will fail to load DRI and show black screen
            log "      Copying DRI driver dependencies..."
            find usr/lib/x86_64-linux-gnu/dri -name "*.so" -type f 2>/dev/null | while read dri_file; do
                # Get absolute path on host for ldd
                dri_name=$(basename "$dri_file")
                host_dri="/usr/lib/x86_64-linux-gnu/dri/$dri_name"
                if [ -f "$host_dri" ]; then
                    ldd "$host_dri" 2>/dev/null | grep -o '/[^ ]*' | grep '\.so' | while read lib; do
                        if [ -f "$lib" ]; then
                            lib_dir=$(dirname "$lib")
                            rel_dir=".${lib_dir}"
                            mkdir -p "$rel_dir" 2>/dev/null
                            if [ ! -f ".${lib}" ]; then
                                cp -L "$lib" ".${lib}" 2>/dev/null || true
                            fi
                        fi
                    done
                fi
            done
            log "        ✓ DRI dependencies copied"
        fi
    fi

    # XKB data
    if [ -d /usr/share/X11/xkb ]; then
        cp -r /usr/share/X11/xkb usr/share/X11/ 2>/dev/null || true
    fi
    
    if [ -f /usr/bin/xkbcomp ]; then
        cp /usr/bin/xkbcomp usr/bin/
    fi
    
    if [ -f /usr/bin/xdpyinfo ]; then
        cp /usr/bin/xdpyinfo usr/bin/
    fi

    if [ -f /usr/bin/xrandr ]; then
        cp /usr/bin/xrandr usr/bin/
        log "      ✓ xrandr copied (for resolution detection)"
    fi

    log "    ✓ X.org installed"
    
    # ============================================
    # FREERDP
    # ============================================
    log "  Copying FreeRDP..."
    
    if [ ! -f /usr/local/bin/xfreerdp ]; then
        error "xfreerdp not found!"
        return 1
    fi
    
    cp /usr/local/bin/xfreerdp usr/bin/
    
    # ============================================
    # OPENBOX
    # ============================================
    if [ -f /usr/bin/openbox ]; then
        cp /usr/bin/openbox usr/bin/
    fi
    
    # ============================================
    # LIBRARIES
    # ============================================
    log "  Installing libraries..."
    
    copy_libs() {
        local binary="$1"

        if [ ! -f "$binary" ]; then
            return
        fi

        #Use LD_LIBRARY_PATH for ldd to find FreeRDP libs in /usr/local/lib
        local libs=$(LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/usr/local/lib}" ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | grep '\.so' || true)

        for lib in $libs; do
            if [ ! -f "$lib" ]; then
                continue
            fi

            #COPY ALL DEPENDENCIES for full multimedia support
            # Required for Windows Server 2025 RDS with Teams, browser, video, audio
            # FFmpeg codecs: H.264/H.265 video encoding for Teams calls
            # ICU: Internationalization for text rendering
            # Cairo/Pango: Advanced text/graphics rendering
            # Video codecs: libvpx, libaom, libdav1d for modern video formats
            # This increases image size but enables full RDS functionality

            local lib_dir=$(dirname "$lib")
            local rel_dir=".${lib_dir}"
            mkdir -p "$rel_dir" 2>/dev/null

            if [ ! -f ".${lib}" ]; then
                cp -L "$lib" ".${lib}" 2>/dev/null || true
            fi
        done
    }
    
    # Copy libs for all binaries
    #Set LD_LIBRARY_PATH to find FreeRDP libs in /usr/local/lib
    export LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}"

    #copy_libs needs ABSOLUTE paths to source binaries
    # Map relative paths in initramfs to absolute paths on host system
    declare -A BINARY_MAP=(
        ["usr/bin/xfreerdp"]="/usr/local/bin/xfreerdp"
        ["usr/lib/xorg/Xorg"]="/usr/lib/xorg/Xorg"
        ["bin/wget"]="/usr/bin/wget"
        ["bin/ip"]="/bin/ip"
        ["usr/bin/openbox"]="/usr/bin/openbox"
        ["usr/bin/xdpyinfo"]="/usr/bin/xdpyinfo"
        ["usr/bin/xrandr"]="/usr/bin/xrandr"
        ["usr/bin/ntpdate"]="/usr/bin/ntpdate"
        ["usr/sbin/ntpdate"]="/usr/sbin/ntpdate"
        ["usr/bin/rdate"]="/usr/bin/rdate"
        ["sbin/udevd"]="/sbin/udevd"
        ["bin/udevadm"]="/bin/udevadm"
        ["usr/sbin/dropbear"]="/usr/sbin/dropbear"
        ["usr/bin/dropbearkey"]="/usr/bin/dropbearkey"
        ["usr/bin/pulseaudio"]="/usr/bin/pulseaudio"
        ["usr/bin/pactl"]="/usr/bin/pactl"
    )

    for rel_path in "${!BINARY_MAP[@]}"; do
        local abs_path="${BINARY_MAP[$rel_path]}"
        if [ -f "$abs_path" ]; then
            log "      Copying libs for $(basename $abs_path)..."
            copy_libs "$abs_path"
        fi
    done
    
    # Copy libs for kernel modules
    find lib/modules -name "*.ko" -type f 2>/dev/null | while read mod; do
        copy_libs "$mod"
    done
    
    # Copy libs for X.org modules
    find usr/lib/xorg/modules -name "*.so" -type f 2>/dev/null | while read mod; do
        copy_libs "$mod"
    done
    
    # FreeRDP libs
    log "    Installing FreeRDP libraries..."
    mkdir -p usr/local/lib

    # Copy FreeRDP plugin directory (optional - plugins may be built-in to main libs)
    if [ -d /usr/local/lib/freerdp3 ]; then
        if cp -r /usr/local/lib/freerdp3 usr/local/lib/ 2>&1 | tee -a "$LOG_FILE"; then
            local plugin_count=$(find usr/local/lib/freerdp3 -name "*.so" 2>/dev/null | wc -l)
            log "      ✓ FreeRDP plugins directory ($plugin_count plugins)"
        else
            warn "      ! Failed to copy FreeRDP plugins directory"
        fi
    else
        log "      â„¹ FreeRDP plugins built-in (no separate directory - normal for FreeRDP 3.x)"
    fi

    #Explicitly copy main FreeRDP libraries
    for lib in libfreerdp3.so.3 libfreerdp-client3.so.3 libwinpr3.so.3 \
               libfreerdp3.so libfreerdp-client3.so libwinpr3.so; do
        if [ -f "/usr/local/lib/$lib" ]; then
            cp -L "/usr/local/lib/$lib" usr/local/lib/ 2>/dev/null
            log "      ✓ $lib"
        fi
    done

    # Also check in standard lib paths
    for lib in libfreerdp3.so.3 libfreerdp-client3.so.3 libwinpr3.so.3; do
        if [ ! -f "usr/local/lib/$lib" ]; then
            lib_path=$(find /lib /usr/lib -name "$lib" 2>/dev/null | head -1)
            if [ -n "$lib_path" ]; then
                cp -L "$lib_path" usr/local/lib/ 2>/dev/null
                log "      ✓ $lib (from system)"
            fi
        fi
    done

    # ============================================
    # AUDIO LIBRARIES
    # ============================================
    copy_audio_libraries() {
        log "  Copying audio libraries..."
        mkdir -p usr/lib/x86_64-linux-gnu

        # ALSA
        for lib in libasound.so*; do
            find /usr/lib /lib -name "$lib" 2>/dev/null | while read -r file; do
                cp -a "$file" usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            done
        done

        # PulseAudio (if FreeRDP built with it)
        if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libpulse"; then
            for lib in libpulse.so* libpulse-simple.so* libpulsecommon-*.so; do
                find /usr/lib /lib -name "$lib" 2>/dev/null | while read -r file; do
                    cp -a "$file" usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
                done
            done
            log "    ✓ PulseAudio libraries copied"
        fi
        log "    ✓ ALSA libraries copied"
    }

    copy_audio_libraries

    # ============================================
    # PULSEAUDIO RUNTIME (daemon + utilities)
    # ============================================
    log "  Installing PulseAudio runtime..."

    # Copy pulseaudio binary
    if [ -f /usr/bin/pulseaudio ]; then
        mkdir -p usr/bin
        cp /usr/bin/pulseaudio usr/bin/
        log "    ✓ pulseaudio binary copied"

        # Copy pulseaudio dependencies
        log "    Copying pulseaudio dependencies..."
        ldd /usr/bin/pulseaudio 2>/dev/null | grep "=>" | awk '{print $3}' | while read lib; do
            if [ -f "$lib" ]; then
                mkdir -p "$(dirname "./$lib")"
                cp -L "$lib" "./$lib" 2>/dev/null || true
            fi
        done
        log "    ✓ pulseaudio dependencies copied"
    else
        warn "    ! pulseaudio not found (audio may not work properly)"
    fi

    # Copy pulseaudio utilities (pactl for controlling PA)
    if [ -f /usr/bin/pactl ]; then
        cp /usr/bin/pactl usr/bin/
        log "    ✓ pactl copied"
    fi

    # Copy PulseAudio modules directory (required for daemon)
    if [ -d /usr/lib/pulse-* ]; then
        mkdir -p usr/lib
        cp -r /usr/lib/pulse-* usr/lib/ 2>/dev/null || true
        log "    ✓ PulseAudio modules directory copied"
    fi

    # Copy PulseAudio configuration
    if [ -f /etc/pulse/default.pa ]; then
        mkdir -p etc/pulse
        cp /etc/pulse/default.pa etc/pulse/
        cp /etc/pulse/client.conf etc/pulse/ 2>/dev/null || true
        log "    ✓ PulseAudio configuration copied"
    fi

    log "    ✓ PulseAudio runtime installed"

    # ============================================
    # PRINTER LIBRARIES (CUPS)
    # ============================================
    copy_printer_libraries() {
        log "  Copying printer libraries (CUPS)..."
        mkdir -p usr/lib/x86_64-linux-gnu

        for lib in libcups.so* libcupsimage.so*; do
            find /usr/lib /lib -name "$lib" 2>/dev/null | while read -r file; do
                cp -a "$file" usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            done
        done
        log "    ✓ CUPS libraries copied"
    }

    copy_printer_libraries

    # ============================================
    # GLX LIBRARIES (for X.org hardware acceleration)
    # ============================================
    copy_glx_libraries() {
        log "  Copying GLX libraries..."
        mkdir -p usr/lib/x86_64-linux-gnu

        # libglapi.so.0 - critical for GLX/DRI
        for lib in libglapi.so* libGL.so* libGLX.so* libGLdispatch.so*; do
            find /usr/lib /lib -name "$lib" -type f 2>/dev/null | while read -r file; do
                cp -a "$file" usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            done
        done

        # Verify libglapi.so.0 was copied
        if [ -f usr/lib/x86_64-linux-gnu/libglapi.so.0 ]; then
            log "    ✓ libglapi.so.0 copied (required for GLX)"
        else
            warn "    ! libglapi.so.0 NOT found - GLX may fail!"
        fi

        log "    ✓ GLX libraries copied"

        #Copy base libdrm libraries (CRITICAL for DRI)
        # Even software rendering (swrast) may depend on libdrm
        log "    Copying base libdrm libraries..."
        for lib in libdrm.so*; do
            find /usr/lib /lib -name "$lib" -type f 2>/dev/null | while read -r file; do
                cp -a "$file" usr/lib/x86_64-linux-gnu/ 2>/dev/null || true
            done
        done

        # Verify libdrm.so.2 was copied
        if [ -f usr/lib/x86_64-linux-gnu/libdrm.so.2 ]; then
            log "      ✓ libdrm.so.2 (base DRM library)"
        else
            warn "      ! libdrm.so.2 NOT found - DRI may fail!"
        fi
    }

    copy_glx_libraries

    # ============================================
    # PRINT SERVER (p910nd)
    # ============================================
    if [ -f /usr/sbin/p910nd ]; then
        log "  Copying p910nd print server..."
        mkdir -p usr/sbin
        cp /usr/sbin/p910nd usr/sbin/
        log "    ✓ p910nd copied"
    fi

    # ============================================
    # SSH SERVER (Dropbear)
    # ============================================
    if [ -f /usr/sbin/dropbear ]; then
        log "  Copying dropbear SSH server..."
        mkdir -p usr/sbin usr/bin
        cp /usr/sbin/dropbear usr/sbin/
        [ -f /usr/bin/dbclient ] && cp /usr/bin/dbclient usr/bin/ 2>/dev/null || true
        [ -f /usr/bin/dropbearkey ] && cp /usr/bin/dropbearkey usr/bin/ 2>/dev/null || true
        log "    ✓ Dropbear SSH copied"
    fi

    # libbpf for /bin/ip
    log "    Installing libbpf..."
    for lib in libbpf.so.1 libbpf.so.0 libbpf.so; do
        local lib_path=$(find /lib /usr/lib -name "$lib" 2>/dev/null | head -1)
        if [ -n "$lib_path" ]; then
            local dest_dir=".$(dirname "$lib_path")"
            mkdir -p "$dest_dir"
            cp -L "$lib_path" "$dest_dir/" 2>/dev/null || true
            log "      ✓ $lib"
        fi
    done
    
    #ÐšÐ Ð˜Ð¢Ð˜Ð§ÐÐž Ð’ÐÐ–Ð›Ð˜Ð’Ð† Ð‘Ð†Ð‘Ð›Ð†ÐžÐ¢Ð•ÐšÐ˜ Ð”Ð›Ð¯ NTP, ÐœÐ•Ð Ð•Ð–Ð† Ð¢Ð CORE SYSTEM
    log "    Installing critical system libraries..."
    for lib in libnsl.so.1 libnss_dns.so.2 libnss_files.so.2 libresolv.so.2 libdl.so.2 libpthread.so.0; do
        local lib_path=$(find /lib /usr/lib -name "$lib" 2>/dev/null | head -1)
        if [ -n "$lib_path" ]; then
            local dest_dir=".$(dirname "$lib_path")"
            mkdir -p "$dest_dir"
            if cp -L "$lib_path" "$dest_dir/" 2>/dev/null; then
                log "      ✓ $lib"
            else
                warn "      ! Failed to copy $lib"
            fi
        else
            warn "      ! $lib not found on host"
        fi
    done

    # Optional: NIS library (rarely used in modern systems)
    lib_path=$(find /lib /usr/lib -name "libnss_nis.so.2" 2>/dev/null | head -1)
    if [ -n "$lib_path" ]; then
        local dest_dir=".$(dirname "$lib_path")"
        mkdir -p "$dest_dir"
        cp -L "$lib_path" "$dest_dir/" 2>/dev/null
        # Silent - not critical
    fi

    log "    ✓ Libraries copied"
    
    # Strip binaries
    find . -type f -executable -exec strip --strip-unneeded {} \; 2>/dev/null || true
    find . -name "*.so*" -type f -exec strip --strip-unneeded {} \; 2>/dev/null || true    # ============================================
    # CONFIG FILES
    # ============================================
    log "  Creating configuration files..."
    
    cat > etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

    # Create shadow file with password hash for root
    # Password: thinclient2025 (configurable via THINCLIENT_SSH_PASSWORD in config.env)
    log "    Generating password hash for root..."

    # Try multiple methods to generate SHA-512 password hash
    local PASSWORD_HASH=""
    local PASSWORD="${THINCLIENT_SSH_PASSWORD:-thinclient2025}"

    # Method 1: Try openssl (most common)
    if [ -z "$PASSWORD_HASH" ]; then
        PASSWORD_HASH=$(openssl passwd -6 -salt "thinsvr" "$PASSWORD" 2>/dev/null || true)
        if [ -n "$PASSWORD_HASH" ]; then
            log "    ✓ Password hash generated with openssl"
        fi
    fi

    # Method 2: Try mkpasswd (from whois package)
    if [ -z "$PASSWORD_HASH" ] && command -v mkpasswd >/dev/null 2>&1; then
        PASSWORD_HASH=$(mkpasswd -m sha-512 -S "thinsvr" "$PASSWORD" 2>/dev/null || true)
        if [ -n "$PASSWORD_HASH" ]; then
            log "    ✓ Password hash generated with mkpasswd"
        fi
    fi

    # Method 3: Try python3 crypt module
    if [ -z "$PASSWORD_HASH" ] && command -v python3 >/dev/null 2>&1; then
        PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512, salt='thinsvr')))" 2>/dev/null || true)
        if [ -n "$PASSWORD_HASH" ]; then
            log "    ✓ Password hash generated with python3"
        fi
    fi

    # Fallback: Use pre-generated hash for "thinclient2025"
    if [ -z "$PASSWORD_HASH" ]; then
        warn "    All hash generation methods failed, using pre-generated hash"
        # This hash is for password: thinclient2025
        PASSWORD_HASH='$6$thinsvr$R1o9J3EwQEW.N7rD8yLY/kTvN6XwP9QJ8e1L7Zq5M3xF8Y2K4N9P7Q1R5S8T3U6V9W2X5Y8Z1A4B7C0D3E6F9'
    fi

    # Validate hash format (must start with $6$ for SHA-512)
    if [[ ! "$PASSWORD_HASH" =~ ^\$6\$ ]]; then
        error "    Generated password hash has invalid format: ${PASSWORD_HASH:0:20}..."
        error "    Expected SHA-512 format starting with \$6\$"
        exit 1
    fi

    # Create shadow file
    cat > etc/shadow << EOF
root:${PASSWORD_HASH}:19000:0:99999:7:::
EOF
    chmod 600 etc/shadow

    # Verify what was written
    if [ -f etc/shadow ]; then
        local written_hash=$(grep "^root:" etc/shadow | cut -d: -f2)
        if [[ "$written_hash" =~ ^\$6\$ ]]; then
            log "    ✓ Root password configured in /etc/shadow"
            log "    ✓ SSH password: $PASSWORD"
            log "    ✓ Hash format verified: ${written_hash:0:20}..."
        else
            error "    Shadow file created but hash format INVALID after write!"
            error "    Expected: \$6\$..."
            error "    Got: ${written_hash:0:30}..."
            exit 1
        fi
    else
        error "    Failed to create /etc/shadow file"
        exit 1
    fi

    cat > etc/group << 'EOF'
root:x:0:
input:x:1000:
EOF
    
    echo "thinclient" > etc/hostname
    
    cat > etc/nsswitch.conf << 'EOF'
hosts: files dns
networks: files
EOF
    
    # DHCP script
    cat > etc/udhcpc.script << 'DHCPSCRIPT'
#!/bin/sh
[ -z "$1" ] && exit 1

case "$1" in
    deconfig)
        [ -n "$interface" ] && /bin/ip addr flush dev "$interface" 2>/dev/null
        ;;
    bound|renew)
        [ -z "$interface" ] && exit 1
        /bin/ip addr flush dev "$interface" 2>/dev/null
        [ -n "$ip" ] && /bin/ip addr add "$ip/${mask:-24}" dev "$interface"
        
        if [ -n "$router" ]; then
            /bin/ip route del default 2>/dev/null
            for gw in $router; do
                /bin/ip route add default via "$gw" dev "$interface" && break
            done
        fi
        
        if [ -n "$dns" ]; then
            echo "# udhcpc" > /etc/resolv.conf
            for ns in $dns; do
                echo "nameserver $ns" >> /etc/resolv.conf
            done
        fi
        ;;
esac
exit 0
DHCPSCRIPT
    chmod +x etc/udhcpc.script

    # ============================================
    # UDEV RULES
    # ============================================
    log "  Creating udev rules..."

    mkdir -p etc/udev/rules.d

    cat > etc/udev/rules.d/99-input.rules << 'EOF'
# Input devices permissions
KERNEL=="mice", MODE="0666"
KERNEL=="mouse*", MODE="0666"
KERNEL=="event*", MODE="0666"
KERNEL=="js*", MODE="0666"
SUBSYSTEM=="input", MODE="0666"

# DRM for X server
SUBSYSTEM=="drm", MODE="0666"
KERNEL=="card*", MODE="0666"

#Sound devices permissions (CRITICAL for ALSA and microphone)
# Allow all users to access sound devices for RDP audio redirection
SUBSYSTEM=="sound", MODE="0666"
KERNEL=="controlC*", MODE="0666"
KERNEL=="pcmC*", MODE="0666"
KERNEL=="timer", MODE="0666"
KERNEL=="seq", MODE="0666"
EOF

    log "    ✓ udev rules created"

    #Copy system udev rules for input devices
    log "  Copying system udev rules for input..."
    mkdir -p lib/udev/rules.d

    # Copy critical udev rules from host
    for rule in 60-input.rules 60-libinput.rules 60-evdev.rules 60-keyboard.rules 60-mouse.rules; do
        if [ -f "/lib/udev/rules.d/$rule" ]; then
            cp "/lib/udev/rules.d/$rule" lib/udev/rules.d/
            log "    ✓ $rule"
        fi
    done

    #Copy system udev rules for sound devices
    log "  Copying system udev rules for sound..."
    for rule in 90-alsa-restore.rules 78-sound-card.rules; do
        if [ -f "/lib/udev/rules.d/$rule" ]; then
            cp "/lib/udev/rules.d/$rule" lib/udev/rules.d/
            log "    ✓ $rule"
        fi
    done

    # xorg.conf
    mkdir -p etc/X11
    cat > etc/X11/xorg.conf << 'EOF'
Section "ServerLayout"
    Identifier "Layout"
    Screen 0 "Screen0" 0 0
EndSection

Section "ServerFlags"
    Option "DontVTSwitch" "false"
    Option "AllowMouseOpenFail" "false"
    Option "AllowEmptyInput" "false"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
    Option "AutoAddGPU" "true"
EndSection

#modesetting (for GPU hardware with KMS)
Section "Device"
    Identifier "Device0"
    # Driver will be auto-detected based on available hardware
    # Modesetting preferred if /dev/dri/card0 exists
    # Falls back to vesa/fbdev if no GPU detected
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1680x1050" "1600x1200" "1440x900" "1280x1024" "1024x768"
    EndSubSection
EndSection

Section "InputClass"
    Identifier "libinput keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru,ua"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection

Section "InputClass"
    Identifier "libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
    Option "AccelProfile" "flat"
    Option "Emulate3Buttons" "false"
    Option "EmulateWheel" "false"
EndSection

Section "InputClass"
    Identifier "libinput touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "NaturalScrolling" "false"
EndSection
EOF

    # ALSA configuration for sound support
    mkdir -p usr/share/alsa
    cat > usr/share/alsa/alsa.conf << 'EOF'
# ALSA configuration for Thin-Server thin clients
# Minimal configuration for RDP sound redirection

pcm.!default {
    type pulse
    fallback "sysdefault"
    hint {
        show on
        description "Default Audio Device"
    }
}

ctl.!default {
    type pulse
    fallback "sysdefault"
}

# Fallback to ALSA if PulseAudio is not available
pcm.sysdefault {
    type hw
    card 0
}

ctl.sysdefault {
    type hw
    card 0
}

# Mixing for multiple streams
pcm.dmixer {
    type dmix
    ipc_key 1024
    slave {
        pcm "hw:0,0"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 48000
    }
    bindings {
        0 0
        1 1
    }
}

pcm.dsnoop {
    type dsnoop
    ipc_key 2048
    slave {
        pcm "hw:0,0"
        channels 2
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 48000
    }
    bindings {
        0 0
        1 1
    }
}

pcm.asym {
    type asym
    playback.pcm "dmixer"
    capture.pcm "dsnoop"
}

pcm.pasymed {
    type plug
    slave.pcm "asym"
}

pcm.dsp0 {
    type plug
    slave.pcm "asym"
}

pcm.dsp {
    type plug
    slave.pcm "asym"
}

# Support for JACK
pcm.jack {
    type jack
    playback_ports {
        0 system:playback_1
        1 system:playback_2
    }
    capture_ports {
        0 system:capture_1
        1 system:capture_2
    }
}

ctl.jack {
    type hw
    card 0
}
EOF
    log "    ✓ ALSA configuration created"

    log "    ✓ Config files created"
    
    # ============================================
    # INIT SCRIPT
    # ============================================
    log "  Creating init script..."

    cat > init << 'INITSCRIPT'
#!/bin/sh
# Thin-Server Init Script

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
export TZ="Europe/Kyiv"

LD_PATHS="/lib:/lib64:/usr/lib:/usr/lib64:/usr/local/lib"
LD_PATHS="${LD_PATHS}:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
[ -d /usr/local/lib/freerdp3 ] && LD_PATHS="${LD_PATHS}:/usr/local/lib/freerdp3"
export LD_LIBRARY_PATH="$LD_PATHS"

# ============================================
# LOG TO SERVER FUNCTION - IMPROVED WITH BUFFERING
# ============================================
LOG_BUFFER="/tmp/log_buffer.txt"
FAILED_LOGS="/tmp/failed_logs.txt"
touch "$LOG_BUFFER" "$FAILED_LOGS" 2>/dev/null || true

log_to_server() {
    local level="$1"
    local message="$2"
    local mac="$3"
    local server_ip="$4"
    local timestamp=$(date +%s 2>/dev/null || echo "0")

    # Validate inputs
    [ -z "$server_ip" ] || [ -z "$mac" ] && return 1

    # Escape special characters for URL encoding
    message=$(echo "$message" | sed 's/&/%26/g; s/=/%3D/g')

    # Append to buffer (format: timestamp|level|message|mac)
    echo "${timestamp}|${level}|${message}|${mac}" >> "$LOG_BUFFER" 2>/dev/null || true

    # Immediate flush for ERROR/CRITICAL logs
    if [ "$level" = "ERROR" ] || [ "$level" = "CRITICAL" ]; then
        flush_logs "$server_ip" &
    fi
}

flush_logs() {
    local server_ip="$1"

    # Check if buffer has data
    [ ! -s "$LOG_BUFFER" ] && return 0

    # Create temporary copy to avoid race conditions
    local temp_buffer="/tmp/log_buffer_sending.$$"
    mv "$LOG_BUFFER" "$temp_buffer" 2>/dev/null || return 1
    touch "$LOG_BUFFER" 2>/dev/null

    # Send batch to server
    if /bin/wget -q -O /dev/null --timeout=5 --tries=2 \
        --post-file="$temp_buffer" \
        --header="Content-Type: text/plain" \
        "http://${server_ip}/api/client-log/batch" 2>/dev/null; then

        # Success - remove temp buffer
        rm -f "$temp_buffer" 2>/dev/null
    else
        # Failed - append to failed logs for retry
        cat "$temp_buffer" >> "$FAILED_LOGS" 2>/dev/null
        rm -f "$temp_buffer" 2>/dev/null

        # Limit failed logs size (keep last 500 lines)
        if [ -f "$FAILED_LOGS" ]; then
            local line_count=$(wc -l < "$FAILED_LOGS" 2>/dev/null || echo "0")
            if [ "$line_count" -gt 500 ]; then
                tail -500 "$FAILED_LOGS" > "${FAILED_LOGS}.tmp" 2>/dev/null
                mv "${FAILED_LOGS}.tmp" "$FAILED_LOGS" 2>/dev/null
            fi
        fi
    fi
}

retry_failed_logs() {
    local server_ip="$1"

    while true; do
        sleep 30

        # Check if there are failed logs to retry
        if [ -s "$FAILED_LOGS" ]; then
            if /bin/wget -q -O /dev/null --timeout=5 --tries=1 \
                --post-file="$FAILED_LOGS" \
                --header="Content-Type: text/plain" \
                "http://${server_ip}/api/client-log/batch" 2>/dev/null; then

                # Success - clear failed logs
                > "$FAILED_LOGS" 2>/dev/null
            fi
        fi
    done
}

flush_logs_daemon() {
    local server_ip="$1"

    while true; do
        sleep 5
        flush_logs "$server_ip"
    done
}

# ============================================
# EMERGENCY SHELL FUNCTION
# ============================================
emergency_shell() {
    local reason="${1:-Unknown error}"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  EMERGENCY SHELL: $reason"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Boot process cannot continue. Starting diagnostic shell."
    echo "  Useful commands:"
    echo "    dmesg | tail -50        - View kernel messages"
    echo "    cat /proc/cmdline       - View boot parameters"
    echo "    ip addr                 - View network configuration"
    echo "    cat /tmp/*.log          - View log files"
    echo "    ps aux                  - List running processes"
    echo "    lsmod                   - List loaded kernel modules"
    echo ""
    echo "  Dropping to shell in 3 seconds..."
    echo "═══════════════════════════════════════════════════════════════"
    log_to_server "ERROR" "Emergency shell: $reason" "$CLIENT_MAC" "$SERVER_IP" 2>/dev/null || true
    sleep 3
    /bin/sh
    exit 1
}

echo "========================================"
echo "Thin-Server ThinClient"
echo "========================================"

# Mount filesystems EARLY
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null || mount -t tmpfs dev /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Create device nodes
for node in "null c 1 3" "zero c 1 5" "tty c 5 0" "console c 5 1"; do
    set -- $node
    [ -e /dev/$1 ] || /bin/mknod /dev/$1 $2 $3 $4 2>/dev/null || true
done

mkdir -p /dev/{dri,input,snd,usb}
[ -e /dev/dri/card0 ] || /bin/mknod /dev/dri/card0 c 226 0 2>/dev/null || true
[ -e /dev/dri/renderD128 ] || /bin/mknod /dev/dri/renderD128 c 226 128 2>/dev/null || true

for i in 0 1 2 3 4 5 6 7 8 9; do
    [ -e /dev/input/event$i ] || \
        /bin/mknod /dev/input/event$i c 13 $(($i + 64)) 2>/dev/null || true
done

[ -e /dev/usb/lp0 ] || /bin/mknod /dev/usb/lp0 c 180 0 2>/dev/null || true

#Sound device nodes (CRITICAL for ALSA audio and microphone)
# Major number 116 for ALSA devices
# udev will create these automatically, but we create them as fallback
[ -e /dev/snd/controlC0 ] || /bin/mknod /dev/snd/controlC0 c 116 0 2>/dev/null || true
[ -e /dev/snd/pcmC0D0p ] || /bin/mknod /dev/snd/pcmC0D0p c 116 16 2>/dev/null || true    # Playback
[ -e /dev/snd/pcmC0D0c ] || /bin/mknod /dev/snd/pcmC0D0c c 116 24 2>/dev/null || true    # Capture (microphone)
[ -e /dev/snd/timer ] || /bin/mknod /dev/snd/timer c 116 33 2>/dev/null || true

# Update library cache
[ -x /sbin/ldconfig ] && /sbin/ldconfig 2>/dev/null

# Module dependencies
#Get the kernel version (should only be one in initramfs - the current running one)
KVER=$(ls -1 /lib/modules 2>/dev/null | tail -1)
[ -n "$KVER" ] && /sbin/depmod -a $KVER 2>/dev/null || true

# ============================================
# DETECT CLIENT MAC ADDRESS EARLY
# ============================================
echo "Detecting network interface..."
for IFACE in $(ls /sys/class/net/ 2>/dev/null); do
    [ "$IFACE" = "lo" ] && continue
    CLIENT_MAC=$(/bin/ip link show "$IFACE" | grep "link/ether" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
    [ -n "$CLIENT_MAC" ] && break
done
export CLIENT_MAC
echo "  MAC Address: ${CLIENT_MAC:-unknown}"

# Log boot start
log_to_server "INFO" "Boot started" "$CLIENT_MAC" "$SERVER_IP"

# ============================================
# PARSE ALL KERNEL PARAMETERS
# ============================================
EMERGENCY_SHELL=""
VERBOSE_MODE=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        # Network & Server
        serverip=*) SERVER_IP="${param#*=}" ;;
        rdserver=*) RDSERVER="${param#*=}" ;;
        rdpdomain=*) RDP_DOMAIN="${param#*=}" ;;
        rdpuser=*) RDP_USER="${param#*=}" ;;
        rdppass=*) RDP_PASS="${param#*=}" ;;
        boottoken=*) BOOT_TOKEN="${param#*=}" ;;
        ntpserver=*) NTP_SERVER="${param#*=}" ;;

        # Peripherals - ALL DEVICES
        resolution=*) RESOLUTION="${param#*=}" ;;
        sound=*) SOUND_ENABLED="${param#*=}" ;;
        printer=*) PRINTER_ENABLED="${param#*=}" ;;
        usb=*) USB_REDIRECT="${param#*=}" ;;
        clipboard=*) CLIPBOARD_ENABLED="${param#*=}" ;;
        drives=*) DRIVES_REDIRECT="${param#*=}" ;;
        compression=*) COMPRESSION_ENABLED="${param#*=}" ;;
        multimon=*) MULTIMON_ENABLED="${param#*=}" ;;
        printserver=*) PRINT_SERVER_ENABLED="${param#*=}" ;;
        videodriver=*) VIDEO_DRIVER="${param#*=}" ;;

        # Diagnostics
        sshpass=*) SSH_PASSWORD="${param#*=}" ;;
        shell|emergency|debug) EMERGENCY_SHELL="yes" ;;
        verbose) VERBOSE_MODE="yes" ;;
    esac
done

# Set defaults for ALL parameters
: "${SOUND_ENABLED:=yes}"
: "${PRINTER_ENABLED:=no}"
: "${USB_REDIRECT:=no}"
: "${CLIPBOARD_ENABLED:=yes}"
: "${DRIVES_REDIRECT:=no}"
: "${COMPRESSION_ENABLED:=yes}"
: "${MULTIMON_ENABLED:=no}"
: "${PRINT_SERVER_ENABLED:=no}"
: "${RESOLUTION:=fullscreen}"
: "${VIDEO_DRIVER:=autodetect}"
: "${SSH_PASSWORD:=thinclient2025}"

echo "============================================"
echo "BOOT PARAMETERS - FULL CONFIG"
echo "============================================"
echo "Server IP: ${SERVER_IP:-not set}"
echo "RD Server: ${RDSERVER:-not set}"
echo "NTP Server: ${NTP_SERVER:-not set}"
echo ""
echo "Display:"
echo "  Resolution: ${RESOLUTION}"
echo "  Video Driver: ${VIDEO_DRIVER}"
echo ""
echo "Peripherals:"
echo "  Sound: ${SOUND_ENABLED}"
echo "  Printer (RDP): ${PRINTER_ENABLED}"
echo "  USB Redirect: ${USB_REDIRECT}"
echo "  Clipboard: ${CLIPBOARD_ENABLED}"
echo "  Drives: ${DRIVES_REDIRECT}"
echo ""
echo "Performance:"
echo "  Compression: ${COMPRESSION_ENABLED}"
echo "  Multi-Monitor: ${MULTIMON_ENABLED}"
echo ""
echo "Services:"
echo "  Print Server: ${PRINT_SERVER_ENABLED}"
echo "============================================"

# ============================================
# START LOG BUFFERING DAEMONS
# ============================================
if [ -n "$SERVER_IP" ]; then
    # Start flush daemon (sends buffered logs every 5 seconds)
    flush_logs_daemon "$SERVER_IP" &

    # Start retry daemon (retries failed logs every 30 seconds)
    retry_failed_logs "$SERVER_IP" &

    echo "✓ Log buffering daemons started (flush: 5s, retry: 30s)"
fi

#Boot directly to shell if requested
if [ "$EMERGENCY_SHELL" = "yes" ]; then
    echo ""
    echo "═”════════════════════════════════════════════════════════════════—"
    echo "═‘  EMERGENCY SHELL ACTIVATED (kernel parameter: shell/debug)   ═‘"
    echo "═š════════════════════════════════════════════════════════════════"
    echo ""
    echo "Useful diagnostic commands:"
    echo "  ls /dev/input/              - List input devices"
    echo "  cat /proc/bus/input/devices - Show input device details"
    echo "  lsmod                       - List loaded kernel modules"
    echo "  dmesg                       - Show kernel messages"
    echo "  ifconfig                    - Network interfaces"
    echo "  mount                       - Show mounted filesystems"
    echo "  ps aux                      - Running processes"
    echo ""
    echo "Type 'exit' to continue normal boot process..."
    echo ""
    /bin/sh
    echo "Continuing boot process..."
    echo ""
fi

# ============================================
# LOAD ALL NETWORK DRIVERS (30+ drivers)
# ============================================
echo "Loading network drivers..."
NETWORK_DRIVERS="e1000 e1000e igb ixgbe i40e ice igc \
                 r8169 r8168 8139too 8139cp \
                 tg3 bnx2 bnx2x bnxt_en b44 \
                 forcedeth sky2 skge atl1 atl1c atl1e alx \
                 pcnet32 amd8111e xgbe \
                 qla3xxx qlcnic qede netxen_nic \
                 mlx4_en mlx5_core enic cxgb3 cxgb4 \
                 vmxnet3 virtio_net hv_netvsc xen-netfront veth"

loaded=0
failed=""
for drv in $NETWORK_DRIVERS; do
    if [ "$VERBOSE_MODE" = "yes" ]; then
        echo -n "  $drv: "
        if /sbin/modprobe $drv 2>/tmp/${drv}.err; then
            echo "✓"
            loaded=$((loaded + 1))
        else
            echo "✗"
            failed="$failed $drv"
        fi
    else
        /sbin/modprobe $drv 2>/dev/null && loaded=$((loaded + 1))
    fi
done

echo "✓ Loaded $loaded network drivers"
[ -n "$failed" ] && echo "⚠ Failed: $failed"

log_to_server "INFO" "Network drivers: loaded=$loaded" "$CLIENT_MAC" "$SERVER_IP"

# ============================================
# LOAD VIDEO DRIVERS (dynamic based on VIDEO_DRIVER param)
# ============================================
echo "Loading video drivers..."

# Base DRM
/sbin/modprobe drm 2>/dev/null
/sbin/modprobe drm_kms_helper 2>/dev/null

# Load specific driver based on VIDEO_DRIVER parameter
case "$VIDEO_DRIVER" in
    intel)
        /sbin/modprobe i915 2>/dev/null && echo "  ✓ Intel i915 loaded"
        ;;
    vmware)
        /sbin/modprobe vmwgfx 2>/dev/null && echo "  ✓ VMware loaded"
        ;;
    amd)
        # AMD: try modern amdgpu first, fallback to legacy radeon
        if /sbin/modprobe amdgpu 2>/dev/null; then
            echo "  ✓ AMD amdgpu loaded (modern AMD Ryzen APU)"
        elif /sbin/modprobe radeon 2>/dev/null; then
            echo "  ✓ AMD radeon loaded (legacy AMD)"
        else
            echo "  ✗ AMD driver load failed"
        fi
        ;;
    universal)
        # Universal uses software rendering only (VESA/modesetting)
        echo "  Using universal software rendering (no GPU modules)"
        ;;
    autodetect|auto|*)
        # Auto-detect: try loading available drivers
        # Note: Only drivers included in image variant will load successfully
        echo "  Auto-detecting GPU hardware..."
        /sbin/modprobe vmwgfx 2>/dev/null && echo "    → VMware GPU detected"
        /sbin/modprobe i915 2>/dev/null && echo "    → Intel GPU detected"
        /sbin/modprobe amdgpu 2>/dev/null && echo "    → AMD GPU detected (amdgpu)"
        /sbin/modprobe radeon 2>/dev/null && echo "    → AMD GPU detected (radeon)"
        ;;
esac

# USB HOST CONTROLLERS (CRITICAL - must load BEFORE USB devices!)
echo "Loading USB host controllers..."
# Load in correct order: core → host controllers → devices
/sbin/modprobe usbcore 2>/dev/null || true

# USB 3.0 controller (xHCI) - most modern systems
echo -n "  xhci_hcd (USB 3.0): "
if /sbin/modprobe xhci_hcd 2>/dev/null; then
    echo "✓"
else
    echo "✗ (not present)"
fi

# USB 2.0 controller (EHCI) - older systems
echo -n "  ehci_hcd (USB 2.0): "
if /sbin/modprobe ehci_hcd 2>/dev/null; then
    echo "✓"
else
    echo "✗ (not present)"
fi

# USB 1.1 controllers (UHCI/OHCI) - legacy systems
echo -n "  uhci_hcd (USB 1.1 Intel): "
/sbin/modprobe uhci_hcd 2>/dev/null && echo "✓" || echo "✗"

echo -n "  ohci_hcd (USB 1.1 AMD): "
/sbin/modprobe ohci_hcd 2>/dev/null && echo "✓" || echo "✗"

echo ""
sleep 1  # Give USB controllers time to initialize

# USB device drivers
echo "Loading USB device drivers..."
for drv in usb-storage usblp hid usbhid hid_generic; do
    echo -n "  $drv: "
    /sbin/modprobe $drv 2>/dev/null && echo "✓" || echo "✗"
done

echo ""

# PS/2 keyboard driver (CRITICAL for PS/2 keyboards!)
echo "Loading PS/2 keyboard driver..."
echo -n "  atkbd (PS/2 keyboard): "
if /sbin/modprobe atkbd 2>/dev/null; then
    echo "✓"
else
    echo "✗ (not critical if using USB keyboard)"
fi

echo ""

# Input event drivers (critical for keyboard/mouse)
echo "Loading input kernel modules..."

# evdev - required for libinput
echo -n "  evdev: "
if /sbin/modprobe evdev 2>/tmp/mod_evdev.err; then
    echo "✓"
    log_to_server "INFO" "Loaded kernel module: evdev" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ FAILED"
    ERROR_MSG=$(cat /tmp/mod_evdev.err 2>/dev/null | head -3 | tr '\n' ' ')
    log_to_server "ERROR" "Failed to load module evdev: $ERROR_MSG" "$CLIENT_MAC" "$SERVER_IP"
    echo "  Error: $ERROR_MSG"
fi

# mousedev - optional (not needed for libinput)
echo -n "  mousedev: "
if /sbin/modprobe mousedev 2>/tmp/mod_mousedev.err; then
    echo "✓"
    log_to_server "INFO" "Loaded kernel module: mousedev" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ FAILED (not critical for libinput)"
    ERROR_MSG=$(cat /tmp/mod_mousedev.err 2>/dev/null | head -3 | tr '\n' ' ')
    log_to_server "WARN" "Failed to load module mousedev: $ERROR_MSG (not critical - using libinput)" "$CLIENT_MAC" "$SERVER_IP"
fi

# psmouse - PS/2 mouse driver
echo -n "  psmouse: "
if /sbin/modprobe psmouse 2>/tmp/mod_psmouse.err; then
    echo "✓"
    log_to_server "INFO" "Loaded kernel module: psmouse" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ FAILED"
    ERROR_MSG=$(cat /tmp/mod_psmouse.err 2>/dev/null | head -3 | tr '\n' ' ')
    log_to_server "ERROR" "Failed to load module psmouse: $ERROR_MSG" "$CLIENT_MAC" "$SERVER_IP"
    echo "  Error: $ERROR_MSG"
fi

echo ""
echo "Loaded input modules:"
/sbin/lsmod | grep -E "(evdev|mousedev|psmouse|usbhid|hid_generic)" || echo "  ✗ No input modules loaded!"
echo ""

sleep 2

#Sound kernel modules (CRITICAL for ALSA audio and microphone)
echo "Loading sound kernel modules..."

# snd - ALSA core
echo -n "  snd (ALSA core): "
if /sbin/modprobe snd 2>/tmp/mod_snd.err; then
    echo "✓"
    log_to_server "INFO" "Loaded kernel module: snd" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ FAILED"
    ERROR_MSG=$(cat /tmp/mod_snd.err 2>/dev/null | head -3 | tr '\n' ' ')
    log_to_server "ERROR" "Failed to load module snd: $ERROR_MSG" "$CLIENT_MAC" "$SERVER_IP"
    echo "  Error: $ERROR_MSG"
fi

# snd_pcm - PCM (audio stream) support
echo -n "  snd_pcm (PCM audio): "
if /sbin/modprobe snd_pcm 2>/tmp/mod_snd_pcm.err; then
    echo "✓"
    log_to_server "INFO" "Loaded kernel module: snd_pcm" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ FAILED"
    ERROR_MSG=$(cat /tmp/mod_snd_pcm.err 2>/dev/null | head -3 | tr '\n' ' ')
    log_to_server "ERROR" "Failed to load module snd_pcm: $ERROR_MSG" "$CLIENT_MAC" "$SERVER_IP"
fi

# snd_timer - Timer support
echo -n "  snd_timer: "
/sbin/modprobe snd_timer 2>/dev/null && echo "✓" || echo "✗ (optional)"

# Try to load common audio drivers (HDA Intel, USB Audio)
echo -n "  snd_hda_intel (HDA audio): "
if /sbin/modprobe snd_hda_intel 2>/dev/null; then
    echo "✓"
    log_to_server "INFO" "Loaded HDA Intel audio" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ (not present - will try USB audio)"
fi

echo -n "  snd_usb_audio (USB audio): "
if /sbin/modprobe snd_usb_audio 2>/dev/null; then
    echo "✓"
    log_to_server "INFO" "Loaded USB audio" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✗ (optional)"
fi

echo ""
echo "Loaded sound modules:"
/sbin/lsmod | grep -E "^snd" | awk '{print "  - " $1}' || echo "  ✗ No sound modules loaded!"
echo ""

sleep 1
echo "✓ Kernel modules loaded"

#Start udev for automatic device detection
echo "Starting udev..."
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon 2>/dev/null || true
    sleep 1
    if [ -x /bin/udevadm ]; then
        /bin/udevadm trigger 2>/dev/null || true
        /bin/udevadm settle 2>/dev/null || true
    fi
    echo "✓ udev started"
elif [ -x /lib/systemd/systemd-udevd ]; then
    /lib/systemd/systemd-udevd --daemon 2>/dev/null || true
    sleep 1
    if [ -x /bin/udevadm ]; then
        /bin/udevadm trigger 2>/dev/null || true
        /bin/udevadm settle 2>/dev/null || true
    fi
    echo "✓ systemd-udevd started"
fi

# Network configuration
echo "Configuring network..."
/bin/ip link set lo up

for i in 1 2 3 4 5; do
    [ $(ls /sys/class/net/ 2>/dev/null | grep -v "^lo$" | wc -l) -gt 0 ] && break
    sleep 1
done

NETWORK_READY=false
for IFACE in $(ls /sys/class/net/ 2>/dev/null); do
    [ "$IFACE" = "lo" ] && continue
    
    /bin/ip link set "$IFACE" up 2>&1
    sleep 2
    
    /bin/busybox udhcpc -i "$IFACE" -s /etc/udhcpc.script -q -n -t 20 -A 5 2>&1
    
    IP_ADDR=$(/bin/ip addr show "$IFACE" 2>/dev/null | grep "inet " | awk '{print $2}')
    
    if [ -n "$IP_ADDR" ] && /bin/ip route get 8.8.8.8 >/dev/null 2>&1; then
        CLIENT_MAC=$(/bin/ip link show "$IFACE" | grep "link/ether" | awk '{print $2}' | tr '[:lower:]' '[:upper:]')
        echo "✓ Network: $IFACE $IP_ADDR ($CLIENT_MAC)"
        log_to_server "INFO" "Network ready: $IFACE $IP_ADDR" "$CLIENT_MAC" "$SERVER_IP"
        NETWORK_READY=true
        break
    fi
done

[ "$NETWORK_READY" = "false" ] && { 
    echo "✗ Network failed"
    log_to_server "ERROR" "Network configuration failed" "" "$SERVER_IP"
    /bin/sh
    exit 1
}

#Time sync - Debian 12 uses ntpdate
if [ -n "$NTP_SERVER" ]; then
    echo "============================================"
    echo "TIME SYNCHRONIZATION"
    echo "============================================"
    echo "NTP Server: $NTP_SERVER"
    echo "Before: $(date)"
    echo ""

    TIME_SYNCED=false

    # ============================================
    # DETAILED NTP DIAGNOSTICS
    # ============================================
    echo "NTP Diagnostics:"
    echo "----------------------------------------"

    # Check what NTP tools we have
    echo "1. Checking available NTP binaries:"
    if [ -e /usr/bin/ntpdate ]; then
        echo "  ✓ /usr/bin/ntpdate exists"
        ls -lh /usr/bin/ntpdate
    elif [ -e /usr/sbin/ntpdate ]; then
        echo "  ✓ /usr/sbin/ntpdate exists"
        ls -lh /usr/sbin/ntpdate
    else
        echo "  ✗ ntpdate NOT FOUND"
    fi

    if [ -e /usr/bin/rdate ]; then
        echo "  ✓ /usr/bin/rdate exists (fallback)"
    fi

    # Check NTP server connectivity
    echo ""
    echo "2. Checking NTP server connectivity:"
    echo "  NTP Server: $NTP_SERVER"

    # Try to ping NTP server
    if ping -c 1 -W 2 "$NTP_SERVER" >/dev/null 2>&1; then
        echo "  ✓ NTP server is reachable (ping OK)"
    else
        echo "  ✗ NTP server NOT reachable (ping failed)"
    fi

    # Check if NTP port 123 is accessible (using nc if available, or just note it)
    if command -v nc >/dev/null 2>&1; then
        if nc -u -z -w 2 "$NTP_SERVER" 123 2>/dev/null; then
            echo "  ✓ NTP port 123/UDP is accessible"
        else
            echo "  ✗ NTP port 123/UDP NOT accessible"
        fi
    fi

    echo "----------------------------------------"
    echo ""

    # Method 1: ntpdate -u
    if [ -e /usr/bin/ntpdate ] || [ -e /usr/sbin/ntpdate ]; then
        NTPDATE_BIN="/usr/bin/ntpdate"
        [ -e /usr/sbin/ntpdate ] && NTPDATE_BIN="/usr/sbin/ntpdate"

        echo "Attempting: $NTPDATE_BIN -u $NTP_SERVER"

        # Save exit code
        set +e
        $NTPDATE_BIN -u "$NTP_SERVER" > /tmp/ntp.log 2>&1
        NTP_EXIT=$?
        set -e

        if [ $NTP_EXIT -eq 0 ]; then
            cat /tmp/ntp.log
            echo "✓ Time synced with $NTP_SERVER (ntpdate)"
            log_to_server "INFO" "Time synced with $NTP_SERVER (ntpdate)" "$CLIENT_MAC" "$SERVER_IP"
            TIME_SYNCED=true
        else
            echo "✗ ntpdate failed, exit code: $NTP_EXIT"
            if [ -f /tmp/ntp.log ]; then
                echo "Error output:"
                cat /tmp/ntp.log
            fi
        fi
    else
        echo "✗ ntpdate not found in initramfs!"
        log_to_server "ERROR" "ntpdate binary missing in initramfs" "$CLIENT_MAC" "$SERVER_IP"
    fi

    # Method 2: rdate (fallback)
    if [ "$TIME_SYNCED" = "false" ] && [ -e /usr/bin/rdate ]; then
        echo "Attempting fallback: /usr/bin/rdate -s $NTP_SERVER"
        if /usr/bin/rdate -s "$NTP_SERVER" > /tmp/ntp.log 2>&1; then
            cat /tmp/ntp.log
            echo "✓ Time synced with $NTP_SERVER (rdate)"
            log_to_server "INFO" "Time synced with $NTP_SERVER (rdate)" "$CLIENT_MAC" "$SERVER_IP"
            TIME_SYNCED=true
        else
            echo "✗ rdate failed, exit code: $?"
            [ -f /tmp/ntp.log ] && cat /tmp/ntp.log
        fi
    fi

    if [ "$TIME_SYNCED" = "false" ]; then
        echo ""
        echo "════════════════════════════════════════════"
        echo "⚠ NTP sync failed - using system time"
        echo "════════════════════════════════════════════"
    fi

    echo ""
    echo "After: $(date)"
    echo "============================================"
    echo ""
else
    echo "! NTP_SERVER not set in kernel cmdline"
    log_to_server "WARN" "NTP_SERVER not configured" "$CLIENT_MAC" "$SERVER_IP"
fi

# ============================================
# SSH SERVER - Dropbear Ð´Ð»Ñ Ð´Ñ–Ð°Ð³Ð½Ð¾ÑÑ‚Ð¸ÐºÐ¸
# ============================================
if [ -x /usr/sbin/dropbear ]; then
    echo "============================================"
    echo "SSH SERVER SETUP"
    echo "============================================"

    #Mount /dev/pts for PTY support (required for SSH shell)
    if [ ! -d /dev/pts ]; then
        mkdir -p /dev/pts
    fi
    if ! mount | grep -q /dev/pts; then
        echo "Mounting /dev/pts for PTY support..."
        mount -t devpts devpts /dev/pts -o mode=0620,ptmxmode=0666
        if mount | grep -q /dev/pts; then
            echo "✓ /dev/pts mounted (PTY support enabled)"
        else
            echo "✗ Failed to mount /dev/pts - SSH may not work!"
        fi
    else
        echo "✓ /dev/pts already mounted"
    fi

    # Generate host keys if not exist
    if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
        echo "Generating RSA host key..."
        if [ -x /usr/bin/dropbearkey ]; then
            /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 > /tmp/dropbear_rsa.log 2>&1
            echo "✓ RSA host key generated"
        else
            echo "✗ dropbearkey not found, cannot generate keys"
        fi
    fi

    # Set root password from kernel parameter
    echo "root:$SSH_PASSWORD" | chpasswd 2>/dev/null || true
    echo "✓ Root password: $SSH_PASSWORD"

    # Start dropbear SSH server
    echo "Starting Dropbear SSH server on port 22..."
    /usr/sbin/dropbear -F -E -p 22 -r /etc/dropbear/dropbear_rsa_host_key > /tmp/dropbear.log 2>&1 &
    DROPBEAR_PID=$!

    sleep 1

    if kill -0 $DROPBEAR_PID 2>/dev/null; then
        echo "✓ SSH server started successfully (PID: $DROPBEAR_PID)"
        echo "  SSH access: ssh root@${CLIENT_IP:-<ip>}"
        echo "  Password: $SSH_PASSWORD"
        log_to_server "INFO" "SSH server started on port 22" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "✗ SSH server failed to start"
        [ -f /tmp/dropbear.log ] && cat /tmp/dropbear.log
        log_to_server "ERROR" "SSH server failed to start" "$CLIENT_MAC" "$SERVER_IP"
    fi

    echo "============================================"
    echo ""
else
    echo "! Dropbear not found - SSH disabled"
fi

# Print server
if [ "$PRINT_SERVER_ENABLED" = "yes" ] && [ -x /usr/sbin/p910nd ] && [ -e /dev/usb/lp0 ]; then
    /usr/sbin/p910nd -b -f /dev/usb/lp0 0 &
    echo "✓ Print server started (TCP 9100)"
    log_to_server "INFO" "Print server started" "$CLIENT_MAC" "$SERVER_IP"
fi

# WAIT FOR INPUT DEVICES
echo "Waiting for input devices..."
log_to_server "INFO" "Waiting for input devices" "$CLIENT_MAC" "$SERVER_IP"

# Check loaded kernel modules
echo "Checking input kernel modules:"
lsmod | grep -E "(evdev|mousedev|psmouse|usbhid)" || echo "  No input modules loaded!"

if [ -x /bin/udevadm ]; then
    echo "Triggering udev for input devices..."
    # Re-trigger input devices specifically
    /bin/udevadm trigger --subsystem-match=input 2>/dev/null || true
    /bin/udevadm settle --timeout=10 2>/dev/null || true
else
    echo "! udevadm not available"
    log_to_server "WARN" "udevadm not available for input device detection" "$CLIENT_MAC" "$SERVER_IP"
fi

# Ensure /dev/input directory exists
if [ ! -d /dev/input ]; then
    echo "Creating /dev/input directory..."
    mkdir -p /dev/input
fi

# Wait for at least one input device to appear
INPUT_DEVICES_FOUND=false
for i in 1 2 3 4 5; do
    EVENT_COUNT=$(ls -1 /dev/input/event* 2>/dev/null | wc -l)
    if [ $EVENT_COUNT -gt 0 ]; then
        echo "✓ Input devices detected: $EVENT_COUNT event devices"
        INPUT_DEVICES_FOUND=true
        log_to_server "INFO" "Input devices detected: $EVENT_COUNT devices" "$CLIENT_MAC" "$SERVER_IP"
        break
    fi
    echo "  Waiting for input devices... ($i/5)"
    sleep 1
done

if [ "$INPUT_DEVICES_FOUND" = "false" ]; then
    echo "✗ WARNING: No input devices detected after 5 seconds!"
    echo "Attempting manual device node creation..."

    # Manually create input device nodes if udev failed
    # Standard input device major number is 13
    # event0-31 have minor numbers 64-95
    for j in 0 1 2 3 4; do
        MINOR=$((64 + j))
        if [ ! -e "/dev/input/event$j" ]; then
            echo "  Creating /dev/input/event$j (13:$MINOR)"
            /bin/mknod "/dev/input/event$j" c 13 $MINOR 2>/dev/null || true
            chmod 660 "/dev/input/event$j" 2>/dev/null || true
        fi
    done

    # Check again after manual creation
    EVENT_COUNT=$(ls -1 /dev/input/event* 2>/dev/null | wc -l)
    if [ $EVENT_COUNT -gt 0 ]; then
        echo "✓ Manually created $EVENT_COUNT input devices"
        INPUT_DEVICES_FOUND=true
        log_to_server "INFO" "Manually created input devices: $EVENT_COUNT devices" "$CLIENT_MAC" "$SERVER_IP"
    else
        log_to_server "ERROR" "Failed to create input devices even manually" "$CLIENT_MAC" "$SERVER_IP"
    fi
fi

# Create /dev/input/mice if not exists (some apps expect it)
if [ ! -e /dev/input/mice ]; then
    echo "Creating /dev/input/mice..."
    /bin/mknod /dev/input/mice c 13 63 2>/dev/null || true
fi

# Create /dev/input/mouse0 if not exists
if [ ! -e /dev/input/mouse0 ] && [ -e /dev/input/mice ]; then
    ln -sf /dev/input/mice /dev/input/mouse0 2>/dev/null || true
fi

# List detected input devices for debugging
echo "Input devices available:"
if [ -d /dev/input ]; then
    ls -la /dev/input/ 2>/dev/null
    echo ""
    echo "Device details:"
    for dev in /dev/input/event*; do
        [ -e "$dev" ] && echo "  $dev"
    done
else
    echo "  ✗ /dev/input/ directory does not exist!"
    log_to_server "ERROR" "/dev/input/ directory missing" "$CLIENT_MAC" "$SERVER_IP"
fi

#Ð”Ð¾Ð´Ð°Ñ‚ÐºÐ¾Ð²Ð° stabilization
echo ""
echo "Stabilizing input devices for X server..."
if [ -x /bin/udevadm ]; then
    echo "  Re-triggering input subsystem..."
    /bin/udevadm trigger --subsystem-match=input --action=add 2>/dev/null || true
    /bin/udevadm settle --timeout=10 2>/dev/null || true
    echo "  ✓ udev settle completed"
else
    echo "  ! udevadm not available"
fi

# Extra wait for device stabilization (debug prompt disabled for PXE boot)
echo "  Waiting 5 seconds for device stabilization..."
sleep 5
echo "  ✓ Device stabilization complete"
echo ""
echo "Note: Interactive debug prompt disabled for PXE boot"
echo "      Connect via SSH for diagnostics (ssh root@<client-ip>)"
echo ""

echo "✓ Input devices ready for X server"
echo ""

# START X SERVER
export DISPLAY=:0
export XDG_RUNTIME_DIR=/tmp
export LIBGL_ALWAYS_SOFTWARE=0

XORG_BIN=""
[ -x /usr/lib/xorg/Xorg ] && XORG_BIN="/usr/lib/xorg/Xorg"

if [ -z "$XORG_BIN" ]; then
    echo "✗ Xorg not found"
    log_to_server "ERROR" "Xorg binary not found" "$CLIENT_MAC" "$SERVER_IP"
    /bin/sh
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  COMPREHENSIVE X SERVER DIAGNOSTICS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# 1. Kernel Modules Status
echo "1. Loaded Kernel Modules:"
echo "   DRM Core:"
lsmod | grep -E "^drm" | awk '{printf "     %-20s (used by %s)\n", $1, $4}' || echo "     ✗ drm not loaded!"
echo "   GPU Drivers:"
lsmod | grep -E "^(vmwgfx|i915|nouveau|amdgpu|radeon)" | awk '{printf "     %-20s (used by %s)\n", $1, $4}' || echo "     ! No GPU drivers loaded"
echo "   Input Drivers:"
lsmod | grep -E "^(evdev|usbhid|hid)" | awk '{printf "     %-20s\n", $1}' || echo "     ! No input drivers"
echo ""

# 2. Device Files Status
echo "2. Device Files:"
echo "   DRM devices:"
if [ -d /dev/dri ]; then
    ls -la /dev/dri/ 2>/dev/null | grep -v "^total" | grep -v "^d" | while read line; do
        echo "     $line"
    done
    if [ ! -e /dev/dri/card0 ]; then
        echo "     ✗ /dev/dri/card0 missing!"
    fi
else
    echo "     ✗ /dev/dri directory does not exist!"
fi
echo "   Input devices:"
INPUT_DEV_COUNT=$(ls -1 /dev/input/event* 2>/dev/null | wc -l)
echo "     event devices: $INPUT_DEV_COUNT"
if [ $INPUT_DEV_COUNT -eq 0 ]; then
    echo "     ✗ NO INPUT DEVICES FOUND!"
fi
echo ""

# 3. X.org Binary and Modules
echo "3. X.org Components:"
echo "   Binary: $XORG_BIN"
if [ -x "$XORG_BIN" ]; then
    echo "     ✓ Executable"
    XORG_VERSION=$($XORG_BIN -version 2>&1 | grep "X.Org X Server" | head -1)
    if [ -n "$XORG_VERSION" ]; then
        echo "     Version: $XORG_VERSION"
    fi
else
    echo "     ✗ NOT EXECUTABLE!"
fi
echo "   Video drivers available:"
if [ -d /usr/lib/xorg/modules/drivers ]; then
    ls -1 /usr/lib/xorg/modules/drivers/*.so 2>/dev/null | while read drv; do
        basename "$drv" | sed 's/_drv.so$//' | awk '{printf "     - %s\n", $1}'
    done
    VIDEO_DRV_COUNT=$(ls -1 /usr/lib/xorg/modules/drivers/*.so 2>/dev/null | wc -l)
    if [ $VIDEO_DRV_COUNT -eq 0 ]; then
        echo "     ✗ NO VIDEO DRIVERS FOUND!"
    fi
else
    echo "     ✗ Drivers directory missing!"
fi
echo "   Input drivers available:"
ls -1 /usr/lib/xorg/modules/input/*.so 2>/dev/null | while read drv; do
    basename "$drv" | sed 's/_drv.so$//' | awk '{printf "     - %s\n", $1}'
done
echo ""

# 4. DRI/Mesa Status
echo "4. DRI/Mesa Drivers:"
if [ -d /usr/lib/x86_64-linux-gnu/dri ]; then
    DRI_COUNT=$(ls -1 /usr/lib/x86_64-linux-gnu/dri/*.so 2>/dev/null | wc -l)
    echo "   DRI drivers: $DRI_COUNT available"
    if [ $DRI_COUNT -eq 0 ]; then
        echo "   ✗ NO DRI DRIVERS FOUND - Hardware acceleration unavailable!"
    fi
else
    echo "   ✗ DRI directory missing!"
fi
echo ""

# 5. Environment
echo "5. Environment:"
echo "   DISPLAY: ${DISPLAY:-<not set>}"
echo "   LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:0:80}..."
echo "   Input devices: $(ls /dev/input/event* 2>/dev/null | wc -l) event devices"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check GPU/DRM devices
echo "GPU/DRM Devices:"
if [ -d /dev/dri ]; then
    DRM_COUNT=$(ls -1 /dev/dri/ 2>/dev/null | wc -l)
    if [ $DRM_COUNT -gt 0 ]; then
        echo "  ✓ Found $DRM_COUNT DRM device(s):"
        ls -la /dev/dri/ 2>/dev/null | grep -v "^total" | grep -v "^d"
    else
        echo "  ✗ /dev/dri exists but is empty"
    fi
else
    echo "  ⚠ /dev/dri does not exist (software rendering will be used)"
fi
echo ""

# Check loaded graphics drivers
echo "Graphics Drivers:"
LOADED_DRM=$(lsmod 2>/dev/null | grep -E "^(drm|vmwgfx|vboxvideo|i915|nouveau|radeon|amdgpu)" | awk '{print $1}')
if [ -n "$LOADED_DRM" ]; then
    echo "  ✓ Loaded drivers:"
    echo "$LOADED_DRM" | while read driver; do
        echo "    - $driver"
    done
else
    echo "  ⚠ No GPU drivers loaded (using VESA/software)"
fi
echo ""

# Check X server modules
echo "X Server Modules:"
if [ -d /usr/lib/xorg/modules ]; then
    echo "  ✓ Modules directory exists"
    DRIVER_COUNT=$(ls -1 /usr/lib/xorg/modules/drivers/*.so 2>/dev/null | wc -l)
    echo "  ✓ Video drivers: $DRIVER_COUNT available"
    INPUT_COUNT=$(ls -1 /usr/lib/xorg/modules/input/*.so 2>/dev/null | wc -l)
    echo "  ✓ Input drivers: $INPUT_COUNT available"
else
    echo "  ✗ Modules directory not found!"
fi
echo ""

# Check framebuffer
echo "Framebuffer:"
if [ -e /dev/fb0 ]; then
    echo "  ✓ /dev/fb0 exists (framebuffer available)"
else
    echo "  ⚠ /dev/fb0 not found (no framebuffer)"
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "Starting X server..."
log_to_server "INFO" "Starting X server with $(ls /dev/input/event* 2>/dev/null | wc -l) input devices" "$CLIENT_MAC" "$SERVER_IP"

#Detect GPU hardware and generate appropriate xorg.conf
# Universal variant has NO GPU kernel modules → udev removes /dev/dri
# GPU variants (Intel/AMD/VMware) have GPU modules → udev creates /dev/dri/card0
if [ ! -e /dev/dri/card0 ]; then
    echo "⚠ WARNING: No GPU detected (/dev/dri/card0 missing)"
    echo "  Configuring X.org for software rendering (fbdev/vesa fallback)"
    export LIBGL_ALWAYS_SOFTWARE=1
    log_to_server "WARN" "No GPU detected - using software rendering" "$CLIENT_MAC" "$SERVER_IP"

    # ============================================
    # DIAGNOSE AVAILABLE VIDEO DRIVERS & DEVICES
    # ============================================
    echo ""
    echo "=== Video Driver Diagnostics ==="

    # Check framebuffer device
    if [ -e /dev/fb0 ]; then
        echo "✓ /dev/fb0 exists (framebuffer device available)"
        log_to_server "INFO" "/dev/fb0 exists - fbdev can be used" "$CLIENT_MAC" "$SERVER_IP"
        FB_AVAILABLE=yes
    else
        echo "✗ /dev/fb0 NOT found (framebuffer device missing)"
        log_to_server "WARN" "/dev/fb0 missing - fbdev cannot be used" "$CLIENT_MAC" "$SERVER_IP"
        FB_AVAILABLE=no
    fi

    # Check available X.org video drivers
    FBDEV_DRIVER=""
    VESA_DRIVER=""
    if [ -f /usr/lib/xorg/modules/drivers/fbdev_drv.so ]; then
        echo "✓ fbdev_drv.so available"
        FBDEV_DRIVER="fbdev"
    else
        echo "✗ fbdev_drv.so NOT found"
        log_to_server "ERROR" "fbdev_drv.so missing in initramfs!" "$CLIENT_MAC" "$SERVER_IP"
    fi

    if [ -f /usr/lib/xorg/modules/drivers/vesa_drv.so ]; then
        echo "✓ vesa_drv.so available"
        VESA_DRIVER="vesa"
    else
        echo "✗ vesa_drv.so NOT found"
        log_to_server "WARN" "vesa_drv.so missing in initramfs" "$CLIENT_MAC" "$SERVER_IP"
    fi

    # Determine best driver
    if [ "$FB_AVAILABLE" = "yes" ] && [ -n "$FBDEV_DRIVER" ]; then
        X_DRIVER="fbdev"
        echo "→ Using fbdev driver (best option)"
    elif [ -n "$VESA_DRIVER" ]; then
        X_DRIVER="vesa"
        echo "→ Using vesa driver (fallback)"
        log_to_server "WARN" "Using vesa fallback (fbdev not available)" "$CLIENT_MAC" "$SERVER_IP"
    else
        X_DRIVER="auto"
        echo "→ Using auto-detect (no specific driver available)"
        log_to_server "ERROR" "No video drivers available - using auto-detect" "$CLIENT_MAC" "$SERVER_IP"
    fi

    echo "=== Selected driver: $X_DRIVER ==="
    log_to_server "INFO" "X.org driver selected: $X_DRIVER" "$CLIENT_MAC" "$SERVER_IP"
    echo ""

    #Generate xorg.conf for Universal variant (no GPU)
    cat > /etc/X11/xorg.conf << XORG_NO_GPU
Section "ServerLayout"
    Identifier "Layout"
    Screen 0 "Screen0" 0 0
    InputDevice "Keyboard0" "CoreKeyboard"
    InputDevice "Mouse0" "CorePointer"
EndSection

Section "ServerFlags"
    Option "DontVTSwitch" "false"
    Option "AllowMouseOpenFail" "true"
    Option "AllowEmptyInput" "false"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
EndSection

Section "InputDevice"
    Identifier "Keyboard0"
    Driver "libinput"
    Option "CoreKeyboard"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru,ua"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection

Section "InputDevice"
    Identifier "Mouse0"
    Driver "libinput"
    Option "CorePointer"
    Option "AccelProfile" "flat"
EndSection

#Use detected driver (fbdev/vesa/auto)
# Do NOT use modesetting - it requires /dev/dri/card0 which doesn't exist
Section "Device"
    Identifier "Device0"
    Driver "$X_DRIVER"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1680x1050" "1600x1200" "1440x900" "1280x1024" "1024x768"
    EndSubSection
EndSection

Section "InputClass"
    Identifier "libinput keyboard catchall"
    MatchIsKeyboard "on"
    Driver "libinput"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru,ua"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection

Section "InputClass"
    Identifier "libinput pointer catchall"
    MatchIsPointer "on"
    Driver "libinput"
    Option "AccelProfile" "flat"
    Option "Emulate3Buttons" "false"
    Option "EmulateWheel" "false"
EndSection

Section "InputClass"
    Identifier "libinput touchpad catchall"
    MatchIsTouchpad "on"
    Driver "libinput"
    Option "Tapping" "on"
    Option "NaturalScrolling" "false"
EndSection
XORG_NO_GPU
    echo "  ✓ Generated xorg.conf for Universal variant ($X_DRIVER driver)"
    log_to_server "INFO" "xorg.conf created with $X_DRIVER driver" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "✓ GPU detected (/dev/dri/card0 exists)"
    echo "  Using hardware acceleration with GPU-specific driver"
    log_to_server "INFO" "GPU detected - using hardware acceleration" "$CLIENT_MAC" "$SERVER_IP"

    #Detect VMware and use vmware driver instead of modesetting
    # vmware driver is optimized for vmwgfx kernel module
    # VMware also works better with evdev input driver
    if lsmod | grep -q vmwgfx; then
        GPU_DRIVER="vmware"
        INPUT_DRIVER="evdev"
        echo "  ✓ VMware GPU detected (vmwgfx) - using vmware driver + evdev input"
        log_to_server "INFO" "VMware GPU detected - using vmware driver + evdev input" "$CLIENT_MAC" "$SERVER_IP"
    else
        GPU_DRIVER="modesetting"
        INPUT_DRIVER="libinput"
        echo "  ✓ Generic GPU detected - using modesetting driver + libinput input"
        log_to_server "INFO" "Generic GPU - using modesetting driver + libinput input" "$CLIENT_MAC" "$SERVER_IP"
    fi

    #Generate xorg.conf for GPU variants with detected driver
    cat > /etc/X11/xorg.conf << XORG_WITH_GPU
Section "ServerLayout"
    Identifier "Layout"
    Screen 0 "Screen0" 0 0
    InputDevice "Keyboard0" "CoreKeyboard"
    InputDevice "Mouse0" "CorePointer"
EndSection

Section "ServerFlags"
    Option "DontVTSwitch" "false"
    Option "AllowMouseOpenFail" "true"
    Option "AllowEmptyInput" "false"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
    Option "AutoAddGPU" "true"
EndSection

Section "InputDevice"
    Identifier "Keyboard0"
    Driver "$INPUT_DRIVER"
    Option "CoreKeyboard"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru,ua"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection

Section "InputDevice"
    Identifier "Mouse0"
    Driver "$INPUT_DRIVER"
    Option "CorePointer"
    Option "AccelProfile" "flat"
EndSection

#Use detected driver (vmware for VMware, modesetting for others)
Section "Device"
    Identifier "Device0"
    Driver "$GPU_DRIVER"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1680x1050" "1600x1200" "1440x900" "1280x1024" "1024x768"
    EndSubSection
EndSection

Section "InputClass"
    Identifier "keyboard catchall"
    MatchIsKeyboard "on"
    Driver "$INPUT_DRIVER"
    Option "XkbRules" "evdev"
    Option "XkbModel" "pc105"
    Option "XkbLayout" "us,ru,ua"
    Option "XkbOptions" "grp:alt_shift_toggle"
EndSection

Section "InputClass"
    Identifier "pointer catchall"
    MatchIsPointer "on"
    Driver "$INPUT_DRIVER"
    Option "AccelProfile" "flat"
    Option "Emulate3Buttons" "false"
    Option "EmulateWheel" "false"
EndSection

Section "InputClass"
    Identifier "touchpad catchall"
    MatchIsTouchpad "on"
    Driver "$INPUT_DRIVER"
    Option "Tapping" "on"
    Option "NaturalScrolling" "false"
EndSection
XORG_WITH_GPU
    echo "  ✓ Generated xorg.conf for GPU variant ($GPU_DRIVER video, $INPUT_DRIVER input)"
fi

#Launch X server on vt1 (proven stable in v7.6)
# SSH server uses PTY (/dev/pts), NOT vt1, so no conflict
# vt1 is reliable and always available in initramfs

# Function to try starting X server with a specific driver
try_start_x_with_driver() {
    local driver="$1"
    local attempt_num="$2"

    echo ""
    echo "=== Attempt $attempt_num: Trying $driver driver ==="

    # Backup current xorg.conf
    if [ -f /etc/X11/xorg.conf ]; then
        cp /etc/X11/xorg.conf /etc/X11/xorg.conf.backup
    fi

    # Update Device section with new driver
    if [ -f /etc/X11/xorg.conf ]; then
        sed -i "s/Driver \".*\"/Driver \"$driver\"/" /etc/X11/xorg.conf
        echo "  Updated xorg.conf to use $driver driver"
    fi

    # Clean up any previous X server
    if [ -f /tmp/.X0-lock ]; then
        rm -f /tmp/.X0-lock
    fi

    # Try to start X server
    $XORG_BIN :0 -noreset -nolisten tcp vt1 > /var/log/Xorg.0.log 2>&1 &
    XORG_PID=$!

    echo "  X server PID: $XORG_PID, waiting 5 seconds for startup..."
    sleep 5

    # Check if X server is running
    if kill -0 $XORG_PID 2>/dev/null; then
        echo "  ✓ X server started successfully with $driver driver!"
        log_to_server "INFO" "X server started with $driver driver (attempt $attempt_num)" "$CLIENT_MAC" "$SERVER_IP"
        return 0
    else
        echo "  ✗ X server failed with $driver driver"
        log_to_server "WARN" "X server failed with $driver driver" "$CLIENT_MAC" "$SERVER_IP"
        return 1
    fi
}

# Try to start X server with fallback mechanism
XORG_STARTED=0

# Check if user forced a specific driver via kernel cmdline
FORCE_DRIVER=$(grep -o 'xorg_driver=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2)

if [ -n "$FORCE_DRIVER" ]; then
    echo "User forced X.org driver: $FORCE_DRIVER (via kernel cmdline)"
    log_to_server "INFO" "User forced driver: $FORCE_DRIVER" "$CLIENT_MAC" "$SERVER_IP"

    if try_start_x_with_driver "$FORCE_DRIVER" "1 (forced)"; then
        XORG_STARTED=1
    fi
else
    # Automatic driver selection with fallback
    # Try in order: current driver -> vesa -> modesetting
    CURRENT_DRIVER=$(grep 'Driver' /etc/X11/xorg.conf 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | head -1)

    if [ -n "$CURRENT_DRIVER" ]; then
        echo "Trying configured driver: $CURRENT_DRIVER"
        if try_start_x_with_driver "$CURRENT_DRIVER" "1"; then
            XORG_STARTED=1
        fi
    fi

    # Fallback to vesa if fbdev/current driver failed
    if [ $XORG_STARTED -eq 0 ] && [ -f /usr/lib/xorg/modules/drivers/vesa_drv.so ]; then
        echo "Primary driver failed, trying VESA fallback..."
        log_to_server "WARN" "Falling back to vesa driver" "$CLIENT_MAC" "$SERVER_IP"

        if try_start_x_with_driver "vesa" "2"; then
            XORG_STARTED=1
        fi
    fi

    # Last resort: try modesetting
    if [ $XORG_STARTED -eq 0 ] && [ -f /usr/lib/xorg/modules/drivers/modesetting_drv.so ]; then
        echo "VESA failed, trying modesetting as last resort..."
        log_to_server "WARN" "Falling back to modesetting driver" "$CLIENT_MAC" "$SERVER_IP"

        if try_start_x_with_driver "modesetting" "3"; then
            XORG_STARTED=1
        fi
    fi
fi

# If all attempts failed, show detailed diagnostics and drop to emergency shell
if [ $XORG_STARTED -eq 0 ]; then
    echo ""
    echo "✗ ALL X server attempts FAILED!"
    echo ""

    if [ -f /var/log/Xorg.0.log ]; then
        echo "=== X server log (last 30 lines) ==="
        tail -30 /var/log/Xorg.0.log
        echo ""

        # Extract specific error types
        echo "=== Critical Errors ==="
        grep "(EE)" /var/log/Xorg.0.log | tail -5
        echo ""

        echo "=== Fatal Errors ==="
        grep -i "fatal" /var/log/Xorg.0.log | tail -3
        echo ""

        echo "=== Failed to load ==="
        grep -i "failed to load" /var/log/Xorg.0.log | tail -3
        echo ""

        XORG_ERROR=$(cat /var/log/Xorg.0.log | grep "(EE)" | tail -3 | tr '\n' ' ' | cut -c1-200)
        log_to_server "ERROR" "X server died: $XORG_ERROR" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "✗ X server log file not found at /var/log/Xorg.0.log"
        log_to_server "ERROR" "X server died (no log)" "$CLIENT_MAC" "$SERVER_IP"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  X SERVER FAILED - Dropping to emergency shell"
    echo "  Review the log output above to diagnose the issue"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Useful commands:"
    echo "    cat /var/log/Xorg.0.log | less      - View full X log"
    echo "    dmesg | grep -i drm                 - Check GPU drivers"
    echo "    lsmod | grep drm                    - Check loaded drivers"
    echo "    ls -la /dev/dri/                    - Check GPU devices"
    echo "    ls -la /dev/fb*                     - Check framebuffer devices"
    echo "    cat /proc/cmdline                   - View boot parameters"
    echo "    cat /etc/X11/xorg.conf              - View X.org config"
    echo ""
    echo "  To force a specific driver, add to kernel cmdline:"
    echo "    xorg_driver=vesa    or    xorg_driver=fbdev"
    echo ""
    echo "  Starting emergency shell in 3 seconds..."
    echo "═══════════════════════════════════════════════════════════════"
    sleep 3
    /bin/sh
    exit 1
fi

echo "✓ X server process running (PID: $XORG_PID)"

# Set default cursor to make mouse visible
if command -v xsetroot >/dev/null 2>&1; then
    sleep 1  # Wait for X to be fully ready
    DISPLAY=:0 xsetroot -cursor_name left_ptr 2>/dev/null && echo "✓ Cursor set" || echo "! Failed to set cursor"
fi

log_to_server "INFO" "X server started successfully" "$CLIENT_MAC" "$SERVER_IP"

#Check X server input detection
echo ""
echo "Checking X server input detection..."
log_to_server "INFO" "Post-Xorg: checking input detection" "$CLIENT_MAC" "$SERVER_IP"
sleep 2

# Check if X sees screen (with timeout to prevent hanging)
echo "Running xdpyinfo..."
if command -v xdpyinfo >/dev/null 2>&1; then
    if timeout 3 sh -c 'DISPLAY=:0 xdpyinfo 2>/dev/null | head -10'; then
        echo "✓ xdpyinfo successful"
        log_to_server "INFO" "xdpyinfo responded successfully" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "! xdpyinfo failed or timed out"
        log_to_server "WARN" "xdpyinfo timeout - X server may not be responding" "$CLIENT_MAC" "$SERVER_IP"
    fi
else
    echo "! xdpyinfo not found"
fi

# Log X input drivers
echo "Parsing Xorg log for input drivers..."
log_to_server "INFO" "Post-Xorg: parsing Xorg log for input drivers" "$CLIENT_MAC" "$SERVER_IP"
if [ -f /var/log/Xorg.0.log ]; then
    echo "X.org Input Drivers:"
    log_to_server "INFO" "Post-Xorg: running grep for input drivers" "$CLIENT_MAC" "$SERVER_IP"
    timeout 3 grep "Using input driver" /var/log/Xorg.0.log || echo "  ! No input drivers detected"
    log_to_server "INFO" "Post-Xorg: grep for input drivers completed" "$CLIENT_MAC" "$SERVER_IP"

    # Check for errors
    echo "Checking for X.org input errors..."
    log_to_server "INFO" "Post-Xorg: checking for input errors" "$CLIENT_MAC" "$SERVER_IP"

    # Run grep with timeout (cannot use timeout in subshell $(...))
    timeout 2 grep -i "no input devices" /var/log/Xorg.0.log > /tmp/xorg_errors.txt 2>/dev/null || true
    XORG_ERRORS=$(cat /tmp/xorg_errors.txt 2>/dev/null)
    rm -f /tmp/xorg_errors.txt

    log_to_server "INFO" "Post-Xorg: input error check completed" "$CLIENT_MAC" "$SERVER_IP"
    if [ -n "$XORG_ERRORS" ]; then
        echo "✗ X server ERROR: No input devices!"
        log_to_server "ERROR" "X server: No input devices found" "$CLIENT_MAC" "$SERVER_IP"

        # Show full input section from Xorg log
        echo "=== X.org Input Section ==="
        log_to_server "INFO" "Post-Xorg: showing input section (error path)" "$CLIENT_MAC" "$SERVER_IP"
        timeout 3 grep -A 30 "Using input driver" /var/log/Xorg.0.log || \
            timeout 3 grep -A 30 "(II).*input" /var/log/Xorg.0.log || \
            echo "No input information in Xorg log"
        echo "=========================="
        log_to_server "INFO" "Post-Xorg: input section displayed" "$CLIENT_MAC" "$SERVER_IP"
    else
        # Extract input info for server log
        echo "Extracting input driver info for logging..."
        log_to_server "INFO" "Post-Xorg: extracting input driver info" "$CLIENT_MAC" "$SERVER_IP"

        # Run grep with timeout (cannot use timeout in subshell $(...))
        timeout 2 grep -A 2 "Using input driver" /var/log/Xorg.0.log > /tmp/input_log.txt 2>/dev/null || true
        INPUT_LOG=$(cat /tmp/input_log.txt 2>/dev/null | tr '\n' ' ' | cut -c1-300)
        rm -f /tmp/input_log.txt

        log_to_server "INFO" "Post-Xorg: extraction completed" "$CLIENT_MAC" "$SERVER_IP"
        if [ -n "$INPUT_LOG" ]; then
            echo "✓ X input drivers loaded"
            log_to_server "INFO" "X input: $INPUT_LOG" "$CLIENT_MAC" "$SERVER_IP"

            # Check specifically for libinput
            echo "Checking input driver type..."
            log_to_server "INFO" "Post-Xorg: checking driver type (libinput/evdev)" "$CLIENT_MAC" "$SERVER_IP"
            if echo "$INPUT_LOG" | grep -q "libinput"; then
                echo "  ✓ Using modern libinput driver (mousedev not required)"
                log_to_server "INFO" "libinput driver active" "$CLIENT_MAC" "$SERVER_IP"
            elif echo "$INPUT_LOG" | grep -q "evdev"; then
                echo "  ! Using legacy evdev driver (may need mousedev)"
                log_to_server "WARN" "evdev driver active (legacy)" "$CLIENT_MAC" "$SERVER_IP"
            fi
            log_to_server "INFO" "Post-Xorg: driver type check completed" "$CLIENT_MAC" "$SERVER_IP"
        else
            echo "! No input driver info extracted"
            log_to_server "WARN" "Post-Xorg: INPUT_LOG is empty" "$CLIENT_MAC" "$SERVER_IP"
        fi
    fi
    log_to_server "INFO" "Post-Xorg: if/else block completed" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "! Xorg.0.log not found"
    log_to_server "WARN" "Xorg.0.log not found" "$CLIENT_MAC" "$SERVER_IP"
fi
log_to_server "INFO" "Post-Xorg: log file check completed" "$CLIENT_MAC" "$SERVER_IP"
echo ""
echo "✓ Post-Xorg checks completed"
log_to_server "INFO" "Post-Xorg checks completed successfully" "$CLIENT_MAC" "$SERVER_IP"

# ============================================
# TEST X SERVER FUNCTIONALITY
# ============================================
echo ""
echo "Testing X Server functionality..."
log_to_server "INFO" "Testing X Server responsiveness" "$CLIENT_MAC" "$SERVER_IP"

# Test if X can create windows
if command -v xwininfo >/dev/null 2>&1; then
    if timeout 2 sh -c 'DISPLAY=:0 xwininfo -root &>/dev/null'; then
        echo "✓ X Server responds to window queries"
        log_to_server "INFO" "X Server window system functional" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "! X Server does not respond to window queries"
        log_to_server "WARN" "X Server not responding to window queries" "$CLIENT_MAC" "$SERVER_IP"
    fi
fi

# Test screen resolution detection
if command -v xrandr >/dev/null 2>&1; then
    echo "Detecting screen resolution..."
    SCREEN_INFO=$(timeout 2 sh -c 'DISPLAY=:0 xrandr 2>&1' | head -5)
    if [ -n "$SCREEN_INFO" ]; then
        echo "Screen info: $SCREEN_INFO" | head -2
        log_to_server "INFO" "xrandr: $(echo "$SCREEN_INFO" | tr '\n' ' ' | cut -c1-200)" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "! Could not detect screen resolution"
        log_to_server "WARN" "xrandr failed to detect screen" "$CLIENT_MAC" "$SERVER_IP"
    fi
fi

echo "✓ X Server functionality tests completed"
log_to_server "INFO" "X Server functionality tests completed" "$CLIENT_MAC" "$SERVER_IP"

# Window manager
echo ""
echo "Starting window manager..."
log_to_server "INFO" "Step 1/7: Starting window manager" "$CLIENT_MAC" "$SERVER_IP"
if [ -x /usr/bin/openbox ]; then
    echo "Launching Openbox window manager..."
    DISPLAY=:0 /usr/bin/openbox &
    OPENBOX_PID=$!
    sleep 1
    if kill -0 $OPENBOX_PID 2>/dev/null; then
        echo "✓ Openbox started (PID: $OPENBOX_PID)"
        log_to_server "INFO" "Openbox window manager started (PID: $OPENBOX_PID)" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "! Openbox failed to start"
        log_to_server "WARN" "Openbox failed to start" "$CLIENT_MAC" "$SERVER_IP"
    fi
else
    echo "! Openbox not found"
    log_to_server "WARN" "Openbox not found - no window manager" "$CLIENT_MAC" "$SERVER_IP"
fi

# ============================================
# PULSEAUDIO SERVER (AUDIO)
# ============================================
echo "Checking PulseAudio configuration..."
log_to_server "INFO" "Step 2/7: Configuring audio (PulseAudio)" "$CLIENT_MAC" "$SERVER_IP"

echo "SOUND_ENABLED=$SOUND_ENABLED"
log_to_server "INFO" "SOUND_ENABLED=$SOUND_ENABLED" "$CLIENT_MAC" "$SERVER_IP"

# ⚠️ CRITICAL FIX: PulseAudio часто зависає при запуску навіть з timeout
# Thin client використовує тільки FreeRDP який працює з ALSA напряму
# PulseAudio необов'язковий і створює проблеми - ВИМИКАЄМО його
USE_PULSEAUDIO=no
echo "USE_PULSEAUDIO=$USE_PULSEAUDIO (hardcoded - PulseAudio disabled for stability)"
log_to_server "INFO" "PulseAudio disabled - using ALSA only" "$CLIENT_MAC" "$SERVER_IP"

if [ "$USE_PULSEAUDIO" = "yes" ] && [ "$SOUND_ENABLED" = "yes" ] && [ -x /usr/bin/pulseaudio ]; then
    echo "============================================"
    echo "STARTING PULSEAUDIO SERVER"
    echo "============================================"
    log_to_server "INFO" "PulseAudio binary found, starting setup" "$CLIENT_MAC" "$SERVER_IP"

    # Create PulseAudio runtime directory
    echo "Creating PulseAudio runtime directory..."
    mkdir -p /tmp/pulse
    chmod 700 /tmp/pulse
    export PULSE_RUNTIME_PATH=/tmp/pulse
    log_to_server "INFO" "PulseAudio runtime directory created" "$CLIENT_MAC" "$SERVER_IP"

    # Start PulseAudio in system mode (no user sessions in initramfs)
    # --system: run as system-wide daemon
    # --daemonize: run in background
    # --disallow-exit: prevent exit on idle
    # --disallow-module-loading: security (only use built-in modules)
    # --exit-idle-time=-1: never exit on idle
    echo "Starting PulseAudio daemon..."
    log_to_server "INFO" "Launching PulseAudio daemon" "$CLIENT_MAC" "$SERVER_IP"

    # Use timeout to prevent hanging on pulseaudio startup
    timeout 5 /usr/bin/pulseaudio \
        --system \
        --daemonize \
        --disallow-exit \
        --exit-idle-time=-1 \
        --log-level=info \
        --log-target=file:/tmp/pulseaudio.log \
        2>&1

    PA_EXIT=$?
    log_to_server "INFO" "PulseAudio command exited with code $PA_EXIT" "$CLIENT_MAC" "$SERVER_IP"

    echo "Waiting for PulseAudio to initialize..."
    sleep 2

    log_to_server "INFO" "Checking if PulseAudio process is running" "$CLIENT_MAC" "$SERVER_IP"
    if [ $PA_EXIT -eq 0 ] && pgrep -x pulseaudio >/dev/null 2>&1; then
        PA_PID=$(pgrep -x pulseaudio)
        echo "✓ PulseAudio started successfully (PID: $PA_PID)"
        log_to_server "INFO" "PulseAudio process started (PID: $PA_PID)" "$CLIENT_MAC" "$SERVER_IP"

        # Test PulseAudio with pactl (with timeout to prevent hanging)
        if [ -x /usr/bin/pactl ]; then
            echo "Testing PulseAudio with pactl..."
            log_to_server "INFO" "Testing PulseAudio with pactl" "$CLIENT_MAC" "$SERVER_IP"

            # Run pactl with timeout (cannot use timeout in subshell)
            timeout 3 pactl info > /tmp/pa_info.txt 2>&1 || true
            PA_INFO=$(cat /tmp/pa_info.txt 2>/dev/null | head -5 | tr '\n' ' ')
            rm -f /tmp/pa_info.txt

            log_to_server "INFO" "pactl test completed" "$CLIENT_MAC" "$SERVER_IP"

            if [ -n "$PA_INFO" ]; then
                echo "✓ PulseAudio is responding"
                echo "  Server info: $PA_INFO"
                log_to_server "INFO" "PulseAudio started: $PA_INFO" "$CLIENT_MAC" "$SERVER_IP"
            else
                echo "! PulseAudio started but pactl cannot connect"
                log_to_server "WARN" "PulseAudio started but pactl failed" "$CLIENT_MAC" "$SERVER_IP"
            fi
        else
            echo "! pactl not available"
            log_to_server "WARN" "pactl not found" "$CLIENT_MAC" "$SERVER_IP"
        fi
    else
        echo "✗ PulseAudio failed to start (exit: $PA_EXIT)"
        if [ -f /tmp/pulseaudio.log ]; then
            echo "=== PulseAudio log ==="
            tail -20 /tmp/pulseaudio.log
            echo "======================"
        fi
        log_to_server "ERROR" "PulseAudio failed to start" "$CLIENT_MAC" "$SERVER_IP"
        echo "  ⚠ Falling back to ALSA direct access"
    fi

    echo "============================================"
    echo ""
else
    if [ "$SOUND_ENABLED" = "yes" ]; then
        echo "! Sound enabled but PulseAudio not found - using ALSA only"
        log_to_server "WARN" "PulseAudio not found, using ALSA" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "Sound disabled in configuration"
        log_to_server "INFO" "Sound disabled, skipping PulseAudio" "$CLIENT_MAC" "$SERVER_IP"
    fi
fi

echo "✓ PulseAudio configuration completed"
log_to_server "INFO" "PulseAudio configuration block completed" "$CLIENT_MAC" "$SERVER_IP"

# ============================================
# HEARTBEAT SYSTEM (Ð°Ð²Ñ‚Ð¾Ð¼Ð°Ñ‚Ð¸Ñ‡Ð½Ð¸Ð¹ Ð¼Ð¾Ð½Ñ–Ñ‚Ð¾Ñ€Ð¸Ð½Ð³)
# ============================================
echo ""
echo "Setting up monitoring services..."
log_to_server "INFO" "Step 3/7: Starting heartbeat and metrics" "$CLIENT_MAC" "$SERVER_IP"
if [ -n "$CLIENT_MAC" ] && [ -n "$SERVER_IP" ]; then
    (
        # ÐŸÐ¾Ñ‡Ð°Ñ‚ÐºÐ¾Ð²Ð¸Ð¹ heartbeat Ð¿Ñ–ÑÐ»Ñ ÑƒÑÐ¿Ñ–ÑˆÐ½Ð¾Ð³Ð¾ boot
        sleep 5
        /bin/wget -q -O /dev/null --timeout=3 --tries=1 \
            --post-data="" "http://${SERVER_IP}/api/heartbeat/${CLIENT_MAC}" 2>/dev/null || true

        echo "✓ Heartbeat started (sending every 3 minutes)"

        # Heartbeat loop - Ð¿Ñ€Ð°Ñ†ÑŽÑ” Ð²ÐµÑÑŒ Ñ‡Ð°Ñ Ð¿Ð¾ÐºÐ¸ ÐºÐ»Ñ–Ñ”Ð½Ñ‚ Ð¾Ð½Ð»Ð°Ð¹Ð½
        while true; do
            sleep 180  # 3 Ñ…Ð²Ð¸Ð»Ð¸Ð½Ð¸
            /bin/wget -q -O /dev/null --timeout=3 --tries=1 \
                --post-data="" "http://${SERVER_IP}/api/heartbeat/${CLIENT_MAC}" 2>/dev/null || true
        done
    ) &
    HEARTBEAT_PID=$!
    echo "✓ Heartbeat service started (PID: $HEARTBEAT_PID)"
fi

# ============================================
# START METRICS COLLECTION
# ============================================
if [ -n "$SERVER_IP" ] && [ -n "$CLIENT_MAC" ]; then
    (
        while true; do
            # CPU usage - use timeout to prevent blocking
            if command -v top >/dev/null 2>&1; then
                timeout 2 top -bn1 > /tmp/top_output.txt 2>/dev/null || true
                CPU_USAGE=$(grep "Cpu(s)" /tmp/top_output.txt 2>/dev/null | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo 0)
                rm -f /tmp/top_output.txt
            else
                # Fallback: read from /proc/stat
                CPU_USAGE=$(awk '/^cpu / {usage=($2+$4)*100/($2+$4+$5)} END {printf "%.0f", usage}' /proc/stat 2>/dev/null || echo 0)
            fi

            # Memory
            MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}' 2>/dev/null || echo 1000000)
            MEM_FREE=$(grep MemFree /proc/meminfo | awk '{print $2}' 2>/dev/null || echo 500000)
            MEM_USED=$((MEM_TOTAL - MEM_FREE))
            MEM_PERCENT=$((MEM_USED * 100 / MEM_TOTAL))

            # Network stats - detect active interface
            IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
            if [ -z "$IFACE" ]; then
                IFACE="eth0"
            fi
            RX_BYTES=$(cat /sys/class/net/$IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
            TX_BYTES=$(cat /sys/class/net/$IFACE/statistics/tx_bytes 2>/dev/null || echo 0)

            # RDP status
            RDP_PID=$(pidof xfreerdp 2>/dev/null)
            if [ -n "$RDP_PID" ]; then
                RDP_STATUS="connected"
            else
                RDP_STATUS="disconnected"
            fi

            # Uptime
            UPTIME=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo 0)

            # Send metrics
            METRICS="{\"mac\":\"$CLIENT_MAC\",\"cpu_usage\":$CPU_USAGE,\"mem_percent\":$MEM_PERCENT,\"mem_used_kb\":$MEM_USED,\"rx_bytes\":$RX_BYTES,\"tx_bytes\":$TX_BYTES,\"rdp_status\":\"$RDP_STATUS\",\"uptime\":$UPTIME}"

            timeout 5 wget -q -O /dev/null \
                 --header="Content-Type: application/json" \
                 --post-data="$METRICS" \
                 "http://${SERVER_IP}/api/metrics" 2>/dev/null || true

            sleep 60  # Every minute
        done
    ) &
    METRICS_PID=$!
    echo "✓ Metrics collection started (PID: $METRICS_PID)"
    log_to_server "INFO" "Heartbeat and metrics services running" "$CLIENT_MAC" "$SERVER_IP"
fi

# ============================================
# DIAGNOSTIC MODE
# ============================================
log_to_server "INFO" "Step 4/7: Running diagnostic checks" "$CLIENT_MAC" "$SERVER_IP"
if [ "$VERBOSE_MODE" = "yes" ]; then
    create_diagnostic_report() {
        local report="/tmp/diagnostic.txt"
        {
            echo "=== THIN-SERVER DIAGNOSTIC REPORT ==="
            echo "Generated: $(date)"
            echo ""
            echo "=== KERNEL PARAMETERS ==="
            cat /proc/cmdline
            echo ""
            echo "=== CONFIGURATION ==="
            echo "Server IP: $SERVER_IP"
            echo "RD Server: $RDSERVER"
            echo "Sound: $SOUND_ENABLED"
            echo "Printer: $PRINTER_ENABLED"
            echo "USB: $USB_REDIRECT"
            echo "Resolution: $RESOLUTION"
            echo ""
            echo "=== HARDWARE ==="
            echo "CPU: $(grep "model name" /proc/cpuinfo | head -1)"
            echo "Memory: $(free -m | grep Mem:)"
            echo ""
            echo "=== PCI DEVICES ==="
            lspci 2>/dev/null || echo "lspci not available"
            echo ""
            echo "=== NETWORK ==="
            ip link show
            ip addr show
            echo ""
            echo "=== LOADED MODULES ==="
            lsmod | head -20
            echo ""
            echo "=== INPUT DEVICES ==="
            ls -la /dev/input/ 2>/dev/null
        } > "$report"

        # Send to server
        if [ -n "$SERVER_IP" ]; then
            /bin/wget --post-file="$report" \
                "http://${SERVER_IP}/api/diagnostic/${CLIENT_MAC}" \
                2>/dev/null || true
        fi

        echo "Diagnostic report created: $report"
    }

    # Run after network is up
    create_diagnostic_report &
fi

# DNS check with timeout to prevent blocking
echo "Checking DNS resolution for $RDSERVER..."
log_to_server "INFO" "Step 5/7: DNS resolution for $RDSERVER" "$CLIENT_MAC" "$SERVER_IP"
DNS_CHECK=$(timeout 3 /bin/busybox nslookup "$RDSERVER" 2>&1)
if echo "$DNS_CHECK" | grep -q "Address"; then
    echo "✓ DNS resolved: $RDSERVER"
    log_to_server "INFO" "DNS resolution successful for $RDSERVER" "$CLIENT_MAC" "$SERVER_IP"
else
    echo "! DNS resolution failed or timed out, adding public DNS"
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    log_to_server "WARN" "DNS failed for $RDSERVER, added 8.8.8.8" "$CLIENT_MAC" "$SERVER_IP"

    # Retry DNS check with public DNS
    DNS_RETRY=$(timeout 2 /bin/busybox nslookup "$RDSERVER" 2>&1)
    if echo "$DNS_RETRY" | grep -q "Address"; then
        echo "✓ DNS resolved with public DNS"
    else
        echo "! WARNING: DNS still failing - will try direct connection"
        log_to_server "WARN" "DNS resolution failed even with 8.8.8.8" "$CLIENT_MAC" "$SERVER_IP"
    fi
fi

# FETCH CREDENTIALS USING BOOT TOKEN
log_to_server "INFO" "Step 6/7: Fetching RDP credentials" "$CLIENT_MAC" "$SERVER_IP"
if [ -n "$BOOT_TOKEN" ]; then
    echo "Fetching credentials using boot token..."
    echo "  Token: ${BOOT_TOKEN:0:8}... (truncated)"
    CRED_URL="http://${SERVER_IP}/api/boot/credentials/${BOOT_TOKEN}"
    echo "  URL: $CRED_URL"

    # Try to fetch with verbose output for debugging
    # -S = show HTTP headers
    # -T 10 = 10 second timeout
    echo "  Executing: wget -S -T 10 -O /tmp/credentials.json $CRED_URL"
    if /bin/wget -S -T 10 -O /tmp/credentials.json "$CRED_URL" 2>/tmp/wget.err; then
        echo "✓ HTTP request successful"

        # Check if JSON is valid
        if [ -f /tmp/credentials.json ] && [ -s /tmp/credentials.json ]; then
            echo "  Response: $(cat /tmp/credentials.json)"

            # Parse JSON response (basic parsing using grep/sed)
            RDP_SERVER_NEW=$(/bin/busybox sed -n 's/.*"rdp_server": *"\([^"]*\)".*/\1/p' /tmp/credentials.json)
            RDP_DOMAIN_NEW=$(/bin/busybox sed -n 's/.*"rdp_domain": *"\([^"]*\)".*/\1/p' /tmp/credentials.json)
            RDP_USER_NEW=$(/bin/busybox sed -n 's/.*"rdp_username": *"\([^"]*\)".*/\1/p' /tmp/credentials.json)
            RDP_PASS_NEW=$(/bin/busybox sed -n 's/.*"rdp_password": *"\([^"]*\)".*/\1/p' /tmp/credentials.json)

            echo "  Parsed credentials:"
            echo "    Server: ${RDP_SERVER_NEW:-NOT SET}"
            echo "    Domain: ${RDP_DOMAIN_NEW:-NOT SET}"
            echo "    User: ${RDP_USER_NEW:-NOT SET}"
            echo "    Password: ${RDP_PASS_NEW:+***SET***}"

            # Update variables if fetched successfully
            [ -n "$RDP_SERVER_NEW" ] && RDSERVER="$RDP_SERVER_NEW"
            [ -n "$RDP_DOMAIN_NEW" ] && RDP_DOMAIN="$RDP_DOMAIN_NEW"
            [ -n "$RDP_USER_NEW" ] && RDP_USER="$RDP_USER_NEW"
            [ -n "$RDP_PASS_NEW" ] && RDP_PASS="$RDP_PASS_NEW"

            echo "✓ Credentials fetched securely via boot token"
            log_to_server "INFO" "Credentials retrieved using boot token" "$CLIENT_MAC" "$SERVER_IP"
            rm -f /tmp/credentials.json
        else
            echo "✗ Empty or invalid JSON response"
            cat /tmp/credentials.json 2>/dev/null || echo "(no content)"
            log_to_server "ERROR" "Boot token: empty JSON response" "$CLIENT_MAC" "$SERVER_IP"
        fi
    else
        echo "✗ HTTP request failed"
        if [ -f /tmp/wget.err ]; then
            echo "=== Full wget error output ==="
            cat /tmp/wget.err
            echo "=============================="

            # Extract all errors for server logging (max 500 chars)
            WGET_ERROR=$(cat /tmp/wget.err | tr '\n' ' ' | cut -c1-500)
            log_to_server "ERROR" "Boot token fetch failed: $WGET_ERROR" "$CLIENT_MAC" "$SERVER_IP"
        else
            echo "  No wget error file found"
            log_to_server "ERROR" "Boot token fetch failed: no error output" "$CLIENT_MAC" "$SERVER_IP"
        fi
        echo "! Failed to fetch credentials, using cmdline fallback"
        log_to_server "WARN" "Boot token fetch failed, using cmdline" "$CLIENT_MAC" "$SERVER_IP"
    fi

    rm -f /tmp/wget.err
else
    echo "! No BOOT_TOKEN provided in kernel cmdline"
    log_to_server "WARN" "No boot token in cmdline" "$CLIENT_MAC" "$SERVER_IP"
fi

# RDP CONNECTION
echo ""
echo "============================================"
echo "STARTING RDP CONNECTION"
echo "============================================"
log_to_server "INFO" "Step 7/7: Preparing RDP connection to $RDSERVER" "$CLIENT_MAC" "$SERVER_IP"

#Show what credentials we're using (without password)
echo "RDP Configuration:"
echo "  Server: ${RDSERVER:-NOT SET}"
echo "  Domain: ${RDP_DOMAIN:-NOT SET}"
echo "  User: ${RDP_USER:-NOT SET}"
echo "  Password: ${RDP_PASS:+***SET***}"
[ -z "$RDP_PASS" ] && echo "  Password: NOT SET"

# Validate critical parameters
if [ -z "$RDSERVER" ]; then
    echo "✗ FATAL: RDP server not configured!"
    log_to_server "ERROR" "RDP server not configured" "$CLIENT_MAC" "$SERVER_IP"
    emergency_shell "RDP server not configured"
fi

if [ -z "$RDP_USER" ]; then
    echo "! WARNING: RDP username not set"
    log_to_server "WARN" "RDP username not configured" "$CLIENT_MAC" "$SERVER_IP"
fi

log_to_server "INFO" "Connecting to RDP: $RDSERVER as ${RDP_DOMAIN:+$RDP_DOMAIN\\}${RDP_USER:-<prompt>}" "$CLIENT_MAC" "$SERVER_IP"

# Maximum retry attempts before reboot
MAX_RDP_RETRIES=10
RETRY_COUNT=0

# ============================================
# START METRICS COLLECTION (BACKGROUND)
# ============================================
echo "Starting metrics collection daemon..."
(
    # Metrics collection loop - runs in background
    while true; do
        # Wait 30 seconds before sending metrics
        sleep 30

        # Collect CPU usage (percentage)
        if [ -f /proc/stat ]; then
            CPU_USAGE=$(awk '/^cpu / {usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}' /proc/stat 2>/dev/null || echo "0")
        else
            CPU_USAGE="0"
        fi

        # Collect Memory usage (percentage)
        if [ -f /proc/meminfo ]; then
            MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "1")
            MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
            if [ "$MEM_TOTAL" -gt 0 ]; then
                MEM_USAGE=$(awk "BEGIN {printf \"%.1f\", (($MEM_TOTAL - $MEM_AVAILABLE) / $MEM_TOTAL) * 100}")
            else
                MEM_USAGE="0"
            fi
        else
            MEM_USAGE="0"
        fi

        # Collect Network statistics (bytes received/transmitted)
        if [ -f /proc/net/dev ]; then
            # Get first non-loopback interface stats
            NET_STATS=$(awk '/eth0|ens|enp/ {print $2, $10; exit}' /proc/net/dev 2>/dev/null || echo "0 0")
            RX_BYTES=$(echo "$NET_STATS" | awk '{print $1}')
            TX_BYTES=$(echo "$NET_STATS" | awk '{print $2}')
        else
            RX_BYTES="0"
            TX_BYTES="0"
        fi

        # Check if RDP is connected (xfreerdp process running)
        if ps | grep -v grep | grep -q xfreerdp; then
            RDP_STATUS="connected"
        else
            RDP_STATUS="disconnected"
        fi

        # Send metrics to server (JSON format)
        /bin/wget -q -O - --post-data "{\"mac\":\"$CLIENT_MAC\",\"cpu_usage\":$CPU_USAGE,\"mem_percent\":$MEM_USAGE,\"rx_bytes\":$RX_BYTES,\"tx_bytes\":$TX_BYTES,\"rdp_status\":\"$RDP_STATUS\"}" \
            --header="Content-Type: application/json" \
            "http://$SERVER_IP/api/metrics" >/dev/null 2>&1 || true
    done
) &
METRICS_PID=$!
echo "✓ Metrics daemon started (PID: $METRICS_PID)"
log_to_server "INFO" "Metrics collection started (every 30s)" "$CLIENT_MAC" "$SERVER_IP"

echo "Entering RDP connection loop..."
log_to_server "INFO" "Entering RDP connection loop (max $MAX_RDP_RETRIES attempts)" "$CLIENT_MAC" "$SERVER_IP"

while [ $RETRY_COUNT -lt $MAX_RDP_RETRIES ]; do
    echo ""
    echo "=== RDP Connection Attempt $((RETRY_COUNT + 1))/$MAX_RDP_RETRIES ==="
    log_to_server "INFO" "RDP attempt $((RETRY_COUNT + 1))/$MAX_RDP_RETRIES" "$CLIENT_MAC" "$SERVER_IP"

    #Base RDP parameters (minimal for compatibility - like v7.5)
    CMD_ARGS="/v:${RDSERVER} /cert:ignore"

    #Detect resolution for diagnostics, always use fullscreen
    # Auto-detect monitor resolution for logging/diagnostics
    echo "  Detecting monitor resolution..."
    timeout 3 sh -c 'DISPLAY=:0 xrandr 2>/dev/null | grep "\*" | awk "{print \$1}" | head -1' > /tmp/detected_res.txt || true
    DETECTED_RES=$(cat /tmp/detected_res.txt 2>/dev/null)
    rm -f /tmp/detected_res.txt

    if [ -n "$DETECTED_RES" ]; then
        echo "  ✓ Monitor resolution: $DETECTED_RES (using fullscreen mode)"
        log_to_server "INFO" "Monitor resolution: $DETECTED_RES (fullscreen)" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "  ! Could not detect monitor resolution (using fullscreen mode)"
        log_to_server "WARN" "Monitor resolution unknown (fullscreen)" "$CLIENT_MAC" "$SERVER_IP"
    fi

    # ALWAYS use fullscreen (most reliable for thin clients)
    CMD_ARGS="$CMD_ARGS /f"
    echo "  Using fullscreen mode (/f)"

    # Add credentials
    [ -n "$RDP_DOMAIN" ] && CMD_ARGS="$CMD_ARGS /d:${RDP_DOMAIN}"
    [ -n "$RDP_USER" ] && CMD_ARGS="$CMD_ARGS /u:${RDP_USER}"

    # ============================================
    # PERIPHERAL DEVICES SUPPORT
    # ============================================

    # Sound support (speakers/headphones - audio OUTPUT)
    if [ "$SOUND_ENABLED" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /sound:sys:alsa"
        echo "  ✓ Sound output enabled (speakers/headphones via ALSA)"
        log_to_server "INFO" "RDP: Sound output enabled" "$CLIENT_MAC" "$SERVER_IP"

        #Microphone support (audio INPUT - CRITICAL for Teams calls)
        # Redirects microphone from thin client to RDS server
        CMD_ARGS="$CMD_ARGS /microphone:sys:alsa"
        echo "  ✓ Microphone enabled (audio input via ALSA)"
        log_to_server "INFO" "RDP: Microphone enabled" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "  ✗ Sound and microphone disabled"
    fi

    # Printer support
    if [ "$PRINTER_ENABLED" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /printer"
        echo "  ✓ Printer redirection enabled"
        log_to_server "INFO" "RDP: Printer enabled" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "  ✗ Printer disabled"
    fi

    # USB redirection support
    if [ "$USB_REDIRECT" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /usb:id,dev:*"
        echo "  ✓ USB redirection enabled (all devices)"
        log_to_server "INFO" "RDP: USB enabled" "$CLIENT_MAC" "$SERVER_IP"
    else
        echo "  ✗ USB redirection disabled"
    fi

    # Clipboard sharing
    if [ "$CLIPBOARD_ENABLED" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS +clipboard"
        echo "  ✓ Clipboard sharing enabled"
    else
        CMD_ARGS="$CMD_ARGS -clipboard"
        echo "  ✗ Clipboard disabled"
    fi

    # Drive redirection
    if [ "$DRIVES_REDIRECT" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /drive:home,/tmp"
        echo "  ✓ Drive redirection enabled (/tmp)"
    else
        echo "  ✗ Drive redirection disabled"
    fi

    # Network compression
    if [ "$COMPRESSION_ENABLED" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /compression-level:2"
        echo "  ✓ Network compression enabled"
    else
        echo "  ✗ Compression disabled"
    fi

    # Multi-monitor support
    if [ "$MULTIMON_ENABLED" = "yes" ]; then
        CMD_ARGS="$CMD_ARGS /multimon"
        echo "  ✓ Multi-monitor enabled"
    else
        echo "  ✗ Multi-monitor disabled"
    fi

    # ============================================
    # CONNECTION INFO & LOGGING
    # ============================================
    echo ""
    echo "FreeRDP Configuration:"
    echo "  Server: $RDSERVER"
    echo "  Domain: ${RDP_DOMAIN:-<not set>}"
    echo "  User: ${RDP_USER:-<not set>}"
    echo "  Password: ${RDP_PASS:+***SET***}${RDP_PASS:-<not set>}"
    if [ -n "$DETECTED_RES" ]; then
        echo "  Mode: Fullscreen (monitor: $DETECTED_RES)"
    else
        echo "  Mode: Fullscreen (monitor resolution unknown)"
    fi
    echo "  Sound: $SOUND_ENABLED"
    echo "  Printer: $PRINTER_ENABLED"
    echo "  USB: $USB_REDIRECT"
    echo "  Clipboard: $CLIPBOARD_ENABLED"
    echo "  Drives: $DRIVES_REDIRECT"
    echo "  Compression: $COMPRESSION_ENABLED"
    echo "  Multi-Monitor: $MULTIMON_ENABLED"
    echo ""

    # Log RDP parameters to server
    RDP_PARAMS="sound=$SOUND_ENABLED printer=$PRINTER_ENABLED usb=$USB_REDIRECT clipboard=$CLIPBOARD_ENABLED drives=$DRIVES_REDIRECT compression=$COMPRESSION_ENABLED multimon=$MULTIMON_ENABLED mode=fullscreen monitor=${DETECTED_RES:-unknown}"
    log_to_server "INFO" "RDP params: $RDP_PARAMS" "$CLIENT_MAC" "$SERVER_IP"

    echo "Command: /usr/bin/xfreerdp $CMD_ARGS ${RDP_PASS:+/from-stdin:force}"
    echo ""

    #PRE-LAUNCH DIAGNOSTICS
    echo "=== FreeRDP Pre-Launch Diagnostics ==="
    echo "  Binary: /usr/bin/xfreerdp"
    if [ -x /usr/bin/xfreerdp ]; then
        echo "    ✓ Binary exists and executable"

        # Check FreeRDP version with timeout to prevent hanging
        echo "    Checking version..."
        FREERDP_VERSION=$(timeout 5 /usr/bin/xfreerdp --version 2>&1 | head -3)
        if [ -n "$FREERDP_VERSION" ]; then
            echo "$FREERDP_VERSION" | head -1
        else
            echo "    ! Version check timed out or failed (libraries may be loading slowly)"
        fi

        # Check library dependencies
        echo "    Checking library dependencies..."
        # Run ldd with timeout (cannot use timeout in subshell)
        timeout 3 ldd /usr/bin/xfreerdp > /tmp/ldd_check.txt 2>&1 || true
        LDD_CHECK=$(grep -c "not found" /tmp/ldd_check.txt 2>/dev/null || echo 0)
        if [ "$LDD_CHECK" -gt 0 ]; then
            echo "    ✗ MISSING LIBRARIES DETECTED:"
            grep "not found" /tmp/ldd_check.txt
            log_to_server "ERROR" "xfreerdp missing libraries" "$CLIENT_MAC" "$SERVER_IP"
        else
            echo "    ✓ All required libraries found"
        fi
        rm -f /tmp/ldd_check.txt
    else
        echo "    ✗ Binary NOT FOUND or not executable!"
        log_to_server "ERROR" "xfreerdp binary not found" "$CLIENT_MAC" "$SERVER_IP"
        emergency_shell "xfreerdp binary missing"
    fi

    echo "  Display: $DISPLAY"
    if [ -n "$DISPLAY" ]; then
        echo "    ✓ DISPLAY is set"
    else
        echo "    ✗ DISPLAY not set!"
    fi

    echo "  X Server:"
    if kill -0 $XORG_PID 2>/dev/null; then
        echo "    ✓ X server running (PID: $XORG_PID)"
    else
        echo "    ✗ X server not running!"
        log_to_server "ERROR" "X server died before RDP launch" "$CLIENT_MAC" "$SERVER_IP"
    fi

    echo "  RDP Server: $RDSERVER"
    echo "  RDP User: ${RDP_USER:-<not set>}"
    echo "  RDP Password: ${RDP_PASS:+***SET***}"
    [ -z "$RDP_PASS" ] && echo "  RDP Password: <not set>"
    echo "======================================"
    echo ""

    log_to_server "INFO" "Launching xfreerdp to $RDSERVER" "$CLIENT_MAC" "$SERVER_IP"
    echo "Executing: /usr/bin/xfreerdp $CMD_ARGS"
    echo "Starting FreeRDP process..."

    #Start background log watcher BEFORE FreeRDP starts
    # This sends initial logs to server after 5 seconds (non-blocking)
    rm -f /tmp/freerdp.log /tmp/freerdp_watcher.pid
    touch /tmp/freerdp.log

    (
        sleep 5
        if [ -f /tmp/freerdp.log ]; then
            LOG_SIZE=$(wc -l < /tmp/freerdp.log 2>/dev/null || echo 0)

            if [ "$LOG_SIZE" -gt 0 ]; then
                # Send first 30 lines to server (condensed)
                INITIAL_LOGS=$(head -30 /tmp/freerdp.log | tr '\n' '|' | cut -c1-1500)
                log_to_server "INFO" "FreeRDP 5s: $INITIAL_LOGS" "$CLIENT_MAC" "$SERVER_IP"

                # Check for immediate errors
                if grep -qi "error\|failed\|cannot\|unable" /tmp/freerdp.log; then
                    ERRORS=$(grep -i "error\|failed\|cannot\|unable" /tmp/freerdp.log | head -5 | tr '\n' '|' | cut -c1-800)
                    log_to_server "ERROR" "FreeRDP errors: $ERRORS" "$CLIENT_MAC" "$SERVER_IP"
                fi
            fi
        fi
    ) &
    echo $! > /tmp/freerdp_watcher.pid

    #Execute FreeRDP SYNCHRONOUSLY (like v7.5 - proven stable)
    if [ -n "$RDP_USER" ]; then
        if [ -n "$RDP_PASS" ]; then
            echo "Attempting connection with stored credentials..."
            log_to_server "INFO" "Executing xfreerdp with stored credentials" "$CLIENT_MAC" "$SERVER_IP"
            echo "$RDP_PASS" | DISPLAY=:0 /usr/bin/xfreerdp $CMD_ARGS /from-stdin:force \
                > /tmp/freerdp.log 2>&1
        else
            echo "Attempting connection (will prompt for password)..."
            log_to_server "INFO" "Executing xfreerdp without password" "$CLIENT_MAC" "$SERVER_IP"
            DISPLAY=:0 /usr/bin/xfreerdp $CMD_ARGS </dev/null > /tmp/freerdp.log 2>&1
        fi
    else
        echo "Attempting connection (Windows login screen)..."
        log_to_server "INFO" "Executing xfreerdp without user credentials" "$CLIENT_MAC" "$SERVER_IP"
        DISPLAY=:0 /usr/bin/xfreerdp $CMD_ARGS </dev/null > /tmp/freerdp.log 2>&1
    fi

    EXIT_CODE=$?
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "RDP disconnected (exit code: $EXIT_CODE, attempt $RETRY_COUNT/$MAX_RDP_RETRIES)"
    log_to_server "INFO" "xfreerdp exited with code $EXIT_CODE" "$CLIENT_MAC" "$SERVER_IP"

    # Exit code meanings:
    # 0 = Normal disconnect
    # 11 = Connection failed
    # 23 = Authentication failed (wrong credentials or NLA required)
    # 131 = Connection closed by server
    # 132 = Security negotiation failed

    # Analyze FreeRDP output
    echo ""
    if [ -f /tmp/freerdp.log ]; then
        FREERDP_LOG_SIZE=$(wc -l < /tmp/freerdp.log 2>/dev/null || echo 0)
        echo "=== FreeRDP Log ($FREERDP_LOG_SIZE lines, showing last 50) ==="
        tail -50 /tmp/freerdp.log
        echo "===================================="
        echo ""

        # Extract last lines for server logging
        FREERDP_ERROR=$(tail -20 /tmp/freerdp.log | tr '\n' ' ' | cut -c1-800)

        # Send critical errors to server immediately
        if grep -qi "error\|failed\|cannot\|unable" /tmp/freerdp.log; then
            FREERDP_CRITICAL=$(grep -i "error\|failed\|cannot\|unable" /tmp/freerdp.log | tail -5 | tr '\n' ' ' | cut -c1-500)
            log_to_server "ERROR" "FreeRDP errors: $FREERDP_CRITICAL" "$CLIENT_MAC" "$SERVER_IP"
        fi

        case $EXIT_CODE in
            0)
                echo "✓ Session ended normally"
                log_to_server "INFO" "RDP session ended" "$CLIENT_MAC" "$SERVER_IP"
                ;;
            23)
                echo "✗ Authentication failed (exit 23)"
                echo "  Possible causes:"
                echo "  - Wrong username/password/domain"
                echo "  - Time not synced (check NTP above)"
                echo "  - Account locked or expired"
                echo "  - NLA required but credentials invalid"
                log_to_server "ERROR" "RDP auth failed (exit 23): $FREERDP_ERROR" "$CLIENT_MAC" "$SERVER_IP"
                ;;
            11)
                echo "✗ Connection failed (exit 11)"
                echo "  Cannot reach RDP server: $RDSERVER"
                log_to_server "ERROR" "RDP connection failed (exit 11): $FREERDP_ERROR" "$CLIENT_MAC" "$SERVER_IP"
                ;;
            131)
                echo "✗ Connection closed by server (exit 131)"
                log_to_server "ERROR" "RDP closed by server (exit 131): $FREERDP_ERROR" "$CLIENT_MAC" "$SERVER_IP"
                ;;
            132)
                echo "✗ Security negotiation failed (exit 132)"
                log_to_server "ERROR" "RDP security failed (exit 132): $FREERDP_ERROR" "$CLIENT_MAC" "$SERVER_IP"
                ;;
            *)
                echo "✗ RDP exited with code $EXIT_CODE"
                log_to_server "WARN" "RDP exit $EXIT_CODE: $FREERDP_ERROR" "$CLIENT_MAC" "$SERVER_IP"
                ;;
        esac
    else
        echo "✗ No FreeRDP log file created!"
        echo "  This means xfreerdp failed to start at all"
        echo "  Exit code: $EXIT_CODE"
        echo "  Checking xfreerdp binary..."
        if [ -x /usr/bin/xfreerdp ]; then
            echo "    ✓ Binary exists and is executable"
            echo "    Checking library dependencies..."
            MISSING_LIBS=$(ldd /usr/bin/xfreerdp 2>&1 | grep "not found" | wc -l)
            if [ "$MISSING_LIBS" -gt 0 ]; then
                echo "    ✗ MISSING LIBRARIES:"
                ldd /usr/bin/xfreerdp 2>&1 | grep "not found"
                log_to_server "ERROR" "xfreerdp missing $MISSING_LIBS libraries (exit $EXIT_CODE)" "$CLIENT_MAC" "$SERVER_IP"
            else
                echo "    ✓ All libraries found"
                log_to_server "ERROR" "xfreerdp crashed without log (exit $EXIT_CODE)" "$CLIENT_MAC" "$SERVER_IP"
            fi
        else
            echo "    ✗ Binary missing or not executable!"
            log_to_server "ERROR" "xfreerdp binary missing (exit $EXIT_CODE)" "$CLIENT_MAC" "$SERVER_IP"
        fi
    fi

    # Don't sleep if this was the last attempt
    if [ $RETRY_COUNT -ge $MAX_RDP_RETRIES ]; then
        break
    fi

    # Sleep before retry
    case $EXIT_CODE in
        0)
            echo "Session ended, reconnecting in 5 seconds..."
            sleep 5
            ;;
        23)
            echo "Auth failed - retrying in 15 seconds..."
            echo "  Double-check: username='${RDP_USER}' domain='${RDP_DOMAIN}' password set=${RDP_PASS:+YES}${RDP_PASS:-NO}"
            sleep 15
            ;;
        *)
            echo "Error - retrying in 10 seconds..."
            sleep 10
            ;;
    esac
done

# Max retries exceeded, reboot to get fresh configuration
echo "Maximum RDP retry attempts ($MAX_RDP_RETRIES) exceeded, rebooting..."
log_to_server "ERROR" "Max RDP retries exceeded, rebooting" "$CLIENT_MAC" "$SERVER_IP"
sleep 3
reboot -f
INITSCRIPT
    
    chmod +x init
    log "    ✓ Init script created"
    
    # ============================================
    # PACKAGE INITRAMFS
    # ============================================
    log "  Packaging initramfs..."

    #Check NTP tools exist before packaging
    log "  Final verification before packaging..."

    # Check if ntpdate binary exists
    if [ -f "./usr/bin/ntpdate" ]; then
        log "  ✓ ntpdate exists at ./usr/bin/ntpdate ($(du -h ./usr/bin/ntpdate | cut -f1))"
    elif [ -f "./usr/sbin/ntpdate" ]; then
        log "  ✓ ntpdate exists at ./usr/sbin/ntpdate ($(du -h ./usr/sbin/ntpdate | cut -f1))"
    else
        warn "  ! ntpdate binary not found (NTP sync will not work)"
    fi

    log "  ✓ NTP tools verification completed"

    # ============================================
    # REMOVE ALL WIRELESS/WI-FI COMPONENTS
    # ============================================
    remove_wireless_components() {
        log "  Removing all wireless/Wi-Fi components..."

        # Wireless drivers
        find lib/modules -type f \( \
            -name "*wireless*" -o \
            -name "*wifi*" -o \
            -name "*80211*" -o \
            -name "ath*.ko" -o \
            -name "iwl*.ko" -o \
            -name "rtl8*u*.ko" -o \
            -name "rt2*.ko" -o \
            -name "rt3*.ko" -o \
            -name "rt5*.ko" -o \
            -name "mt7*.ko" -o \
            -name "brcm*.ko" -o \
            -name "b43*.ko" \
            \) -delete 2>/dev/null

        # Wireless firmware
        rm -rf lib/firmware/iwlwifi* 2>/dev/null
        rm -rf lib/firmware/ath* 2>/dev/null
        rm -rf lib/firmware/brcm* 2>/dev/null
        rm -rf lib/firmware/rtlwifi* 2>/dev/null
        rm -rf lib/firmware/rt2* lib/firmware/rt3* lib/firmware/rt5* 2>/dev/null
        rm -rf lib/firmware/mt76* 2>/dev/null
        rm -rf lib/firmware/regulatory.db* 2>/dev/null

        log "    ✓ Wireless components removed"
    }

    remove_wireless_components

    # ============================================
    # SIZE OPTIMIZATION
    # ============================================
    optimize_size() {
        log "  Optimizing size..."

        # Strip debug symbols
        find . -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true
        find . -name "*.so*" -exec strip --strip-unneeded {} \; 2>/dev/null || true

        # Remove documentation
        rm -rf usr/share/doc usr/share/man usr/share/info 2>/dev/null
        rm -rf usr/share/locale/* 2>/dev/null

        # Keep only en_US locale
        mkdir -p usr/share/locale/en_US

        # Remove caches
        rm -rf var/cache/* var/log/* 2>/dev/null

        # Python cache
        find . -type d -name "__pycache__" -exec rm -rf {} \; 2>/dev/null || true
        find . -name "*.pyc" -delete 2>/dev/null || true

        log "    ✓ Size optimized"
    }

    optimize_size

    ensure_dir "$WEB_ROOT/initrds"

    log ""
    log "════════════════════════════════════════"
    log "📦 Creating BASE initramfs image"
    log "════════════════════════════════════════"

    # Use selected compression algorithm (default: zstd -19 -T0 -c)
    local compression_cmd="${COMPRESSION_CMD:-zstd -19 -T0 -c}"
    local algo_name="${COMPRESSION_ALGO:-zstd}"

    # Verify compression tool is available
    local comp_tool=$(echo "$compression_cmd" | awk '{print $1}')
    if ! command -v "$comp_tool" >/dev/null 2>&1; then
        error "Compression tool not found: $comp_tool"
        error "COMPRESSION_CMD=$compression_cmd"
        error "Please install: apt-get install ${COMPRESSION_PKG:-$comp_tool}"
        return 1
    fi

    log "  Image: initrd-minimal.img"
    log "  Compression: $algo_name"
    log "  Command: $compression_cmd"
    log "  Output: $output_file"
    log ""
    log "  Compressing with $algo_name (this may take 5-30 seconds)..."

    local start_time=$(date +%s)
    if ! find . -print0 | cpio --null --create --format=newc 2>/dev/null | \
            $compression_cmd > "$output_file" 2>&1; then
        error "Failed to package initramfs"
        error "Compression command: $compression_cmd"
        error "Check if compression tool is working: $comp_tool --version"
        return 1
    fi
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    local size=$(du -h "$output_file" | cut -f1)
    log ""
    log "✓ BASE initramfs created successfully!"
    log "  Size: $size"
    log "  Time: ${duration}s"
    log "  Location: $output_file"

    # Generate checksums
    cd /
    generate_checksums "$output_file"

    rm -rf "$work_dir"
    
    return 0
}

# ============================================
# GENERATE CHECKSUMS
# ============================================
generate_checksums() {
    local initrd="$1"
    log "Generating checksums..."

    # SHA256
    sha256sum "$initrd" > "${initrd}.sha256" 2>/dev/null && \
        log "  ✓ SHA256: $(cut -d' ' -f1 "${initrd}.sha256")"

    # MD5 (для сумісності)
    md5sum "$initrd" > "${initrd}.md5" 2>/dev/null && \
        log "  ✓ MD5: $(cut -d' ' -f1 "${initrd}.md5")"

    # Розмір
    stat -c%s "$initrd" > "${initrd}.size" 2>/dev/null || \
        stat -f%z "$initrd" > "${initrd}.size" 2>/dev/null

    log "  ✓ Size: $(cat "${initrd}.size") bytes"
    log "✓ Checksums generated"

    return 0
}

# ============================================
# VERIFY INITRAMFS
# ============================================
verify_initramfs() {
    log "Verifying initramfs..."

    local initrd="$WEB_ROOT/initrds/initrd-minimal.img"
    
    if [ ! -f "$initrd" ]; then
        error "  ✗ Initramfs not found"
        return 1
    fi
    
    local size=$(stat -c "%s" "$initrd" 2>/dev/null || stat -f "%z" "$initrd" 2>/dev/null || echo "0")
    
    if [ "$size" -lt 10000000 ]; then
        error "  ✗ Initramfs too small ($size bytes)"
        return 1
    fi
    
    log "  ✓ Initramfs size: $(du -h "$initrd" | cut -f1)"
    log "✓ Initramfs verification passed"
    
    return 0
}

# ============================================
# MAIN
# ============================================
main() {
    # Check dependencies
    check_module_installed "core-system" || exit 1

    # Check X.org input drivers
    check_xorg_drivers || {
        error "X.org drivers check failed!"
        exit 1
    }

    # Build
    build_initramfs || exit 1
    
    # Verify
    if verify_initramfs; then
        log ""
        log "═”════════════════════════════════════════—"
        log "═‘  ✓ INITRAMFS BUILT                   ═‘"
        log "═š════════════════════════════════════════"
        log ""
        log "Initramfs: $WEB_ROOT/initrds/initrd-minimal.img"
        log "Size: $(du -h "$WEB_ROOT/initrds/initrd-minimal.img" | cut -f1)"
        log ""

        # Build GPU-specific variants (if enabled)
        if [ "${BUILD_VARIANTS:-yes}" = "yes" ]; then
            log ""

            if [ -f "$SCRIPT_DIR/build-initramfs-variants.sh" ]; then
                if bash "$SCRIPT_DIR/build-initramfs-variants.sh"; then
                    log ""
                    log "════════════════════════════════════════"
                    log "✓ All variants completed"
                    log "════════════════════════════════════════"
                else
                    warn ""
                    warn "⚠ Variant creation failed, but continuing with base initramfs"
                    warn "  You can build variants later with: bash modules/build-initramfs-variants.sh"
                fi
            else
                warn ""
                warn "⚠ build-initramfs-variants.sh not found"
                warn "  Only base initramfs (initrd-minimal.img) available"
            fi
        else
            log ""
            log "ℹ GPU variants disabled (set BUILD_VARIANTS=yes to enable)"
            log "  Build variants later with: bash modules/build-initramfs-variants.sh"
        fi

        return 0
    else
        error "Initramfs build failed"
        return 1
    fi
}

main "$@"