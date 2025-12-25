#!/bin/bash
# Thin-Server Module: Build Initramfs Variants for Different Video Cards
# Creates optimized initramfs for different GPU types

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

WORK_DIR="/tmp/initramfs-variants-build"
OUTPUT_DIR="/var/www/thinclient/initrds"
BASE_IMAGE="$WORK_DIR/base"

log "════════════════════════════════════════"
log "Building Initramfs Variants"
log "════════════════════════════════════════"

# ============================================
# CREATE BASE IMAGE
# ============================================
create_base_image() {
    log "Preparing base image for GPU variants..."

    #Don't rebuild initramfs - it's already created!
    # Just extract the existing initrd-minimal.img
    local minimal_img="$OUTPUT_DIR/initrd-minimal.img"

    if [ ! -f "$minimal_img" ]; then
        error "Base image not found: $minimal_img"
        error "This script should be called AFTER creating base initramfs"
        error "Run modules/02-initramfs.sh first"
        return 1
    fi

    log "  Base image: $minimal_img"
    log "  Size: $(du -h "$minimal_img" | cut -f1)"

    rm -rf "$BASE_IMAGE"
    mkdir -p "$BASE_IMAGE"

    log "  Extracting base image..."
    cd "$BASE_IMAGE"

    # Use selected decompression algorithm (default: zstd -dc)
    local decompress_cmd="${DECOMPRESSION_CMD:-zstd -dc}"
    log "  Decompression command: $decompress_cmd"

    # Verify decompression tool is available
    local decomp_tool=$(echo "$decompress_cmd" | awk '{print $1}')
    if ! command -v "$decomp_tool" >/dev/null 2>&1; then
        error "Decompression tool not found: $decomp_tool"
        error "Install: apt-get install ${COMPRESSION_PKG:-$decomp_tool}"
        return 1
    fi

    # Show progress for user
    log "  This will take ~10-30 seconds..."

    # Extract with proper error handling (disable pipefail for cpio warnings)
    set +e
    $decompress_cmd "$minimal_img" 2>/dev/null | cpio -idm 2>/dev/null
    local extract_status=$?
    set -e

    if [ $extract_status -ne 0 ]; then
        error "Failed to extract base image (exit code: $extract_status)"
        error "Decompression command: $decompress_cmd"
        error "Check file: $minimal_img"
        error ""
        error "Debug: Try manually:"
        error "  cd /tmp/test && $decompress_cmd $minimal_img | cpio -idm"
        return 1
    fi

    # Verify extraction worked
    if [ ! -f "init" ] || [ ! -d "bin" ]; then
        error "Extraction succeeded but image structure is wrong"
        error "Missing: init script or bin directory"
        return 1
    fi

    log "✓ Base image extracted successfully ($(ls -1 | wc -l) files/dirs)"
    return 0
}

# ============================================
# ADD VIDEO VARIANT
# ============================================
add_video_variant() {
    local variant=$1
    # No longer need kernel_modules parameter - logic is inside function

    log ""
    log "════════════════════════════════════════"
    log "🎮 Creating GPU variant: ${variant^^}"
    log "════════════════════════════════════════"

    local variant_dir="$WORK_DIR/$variant"
    rm -rf "$variant_dir"
    cp -r "$BASE_IMAGE" "$variant_dir"
    cd "$variant_dir"

    local kernel_ver=$(uname -r)
    local driver_count=0

    log "  Adding GPU kernel modules..."

    #Copy ENTIRE GPU driver directories (includes all dependencies)
    # This ensures all sub-modules and dependencies are included
    case $variant in
        vmware)
            if [ -d "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx" ]; then
                mkdir -p "lib/modules/$kernel_ver/kernel/drivers/gpu/drm"
                cp -r "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx" \
                    "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/" 2>/dev/null && {
                    log "    ✓ vmwgfx directory ($(du -sh lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx 2>/dev/null | awk '{print $1}'))"
                    driver_count=1
                }
            fi
            ;;
        intel)
            if [ -d "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915" ]; then
                mkdir -p "lib/modules/$kernel_ver/kernel/drivers/gpu/drm"
                cp -r "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915" \
                    "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/" 2>/dev/null && {
                    log "    ✓ i915 directory ($(du -sh lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915 2>/dev/null | awk '{print $1}'))"
                    driver_count=1
                }
            fi
            ;;
        amd)
            # AMD variant supports both modern amdgpu and legacy radeon drivers
            if [ -d "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd" ]; then
                mkdir -p "lib/modules/$kernel_ver/kernel/drivers/gpu/drm"
                cp -r "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd" \
                    "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/" 2>/dev/null && {
                    log "    ✓ amd directory (amdgpu) ($(du -sh lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd 2>/dev/null | awk '{print $1}'))"
                    driver_count=1
                }
            fi
            # Legacy radeon driver
            if [ -d "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/radeon" ]; then
                mkdir -p "lib/modules/$kernel_ver/kernel/drivers/gpu/drm"
                cp -r "/lib/modules/$kernel_ver/kernel/drivers/gpu/drm/radeon" \
                    "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/" 2>/dev/null && {
                    log "    ✓ radeon directory (legacy) ($(du -sh lib/modules/$kernel_ver/kernel/drivers/gpu/drm/radeon 2>/dev/null | awk '{print $1}'))"
                }
            fi
            ;;
        universal)
            # Universal variant uses only software rendering (VESA/modesetting)
            # No GPU-specific modules needed - works on all hardware
            log "    ℹ Universal variant uses software rendering (VESA/modesetting)"
            ;;
    esac

    # Add X.org drivers, firmware, and DRI
    log "  Adding GPU-specific components..."
    local xorg_added=0
    local firmware_added=0

    case $variant in
        intel)
            log "    X.org driver:"
            if [ -f /usr/lib/xorg/modules/drivers/intel_drv.so ]; then
                cp /usr/lib/xorg/modules/drivers/intel_drv.so \
                   usr/lib/xorg/modules/drivers/ 2>/dev/null && {
                    log "      ✓ intel_drv.so"
                    xorg_added=1
                }
            else
                log "      ! intel_drv.so not found on host"
            fi

            log "    Firmware:"
            if [ -d /lib/firmware/i915 ]; then
                mkdir -p lib/firmware
                cp -r /lib/firmware/i915 lib/firmware/ 2>/dev/null && {
                    log "      ✓ i915 firmware"
                    firmware_added=1
                }
            fi
            ;;

        vmware)
            log "    X.org driver:"
            if [ -f /usr/lib/xorg/modules/drivers/vmware_drv.so ]; then
                cp /usr/lib/xorg/modules/drivers/vmware_drv.so \
                   usr/lib/xorg/modules/drivers/ 2>/dev/null && {
                    log "      ✓ vmware_drv.so"
                    xorg_added=1
                }
            else
                log "      ! vmware_drv.so not found on host"
            fi
            # VMware doesn't need firmware
            ;;

        amd)
            #Uses modesetting_drv.so from base image
            # AMD GPUs work best with modesetting driver + KMS (Kernel Mode Setting)
            # No need to copy additional X.org driver - modesetting already in base
            log "    X.org driver: modesetting_drv.so (from base image - KMS)"

            log "    Firmware (CRITICAL for AMD Ryzen APU):"
            # AMD amdgpu firmware (modern AMD Ryzen APU with Radeon Graphics)
            if [ -d /lib/firmware/amdgpu ]; then
                mkdir -p lib/firmware
                cp -r /lib/firmware/amdgpu lib/firmware/ 2>/dev/null && {
                    local amdgpu_size=$(du -sh lib/firmware/amdgpu 2>/dev/null | awk '{print $1}')
                    log "      ✓ amdgpu firmware ($amdgpu_size)"
                    firmware_added=1
                }
            else
                warn "      ! amdgpu firmware not found - AMD Ryzen APU will NOT work!"
            fi

            # AMD radeon firmware (legacy AMD GPUs)
            if [ -d /lib/firmware/radeon ]; then
                mkdir -p lib/firmware
                cp -r /lib/firmware/radeon lib/firmware/ 2>/dev/null && {
                    local radeon_size=$(du -sh lib/firmware/radeon 2>/dev/null | awk '{print $1}')
                    log "      ✓ radeon firmware ($radeon_size)"
                }
            fi
            ;;

        universal)
            log "    Using base modesetting/VESA drivers (universal compatibility)"
            ;;
    esac

    # Add GPU-specific DRI drivers (Mesa hardware acceleration)
    log "    DRI drivers (Mesa):"
    if [ -d /usr/lib/x86_64-linux-gnu/dri ]; then
        mkdir -p usr/lib/x86_64-linux-gnu/dri
        local dri_added=0

        case $variant in
            vmware)
                if [ -f /usr/lib/x86_64-linux-gnu/dri/vmwgfx_dri.so ]; then
                    cp -L /usr/lib/x86_64-linux-gnu/dri/vmwgfx_dri.so \
                        usr/lib/x86_64-linux-gnu/dri/ 2>/dev/null && {
                        log "      ✓ vmwgfx_dri.so"
                        dri_added=1
                    }
                fi
                ;;

            intel)
                # Intel has multiple DRI drivers
                for dri in i965_dri.so iris_dri.so crocus_dri.so; do
                    if [ -f /usr/lib/x86_64-linux-gnu/dri/$dri ]; then
                        cp -L /usr/lib/x86_64-linux-gnu/dri/$dri \
                            usr/lib/x86_64-linux-gnu/dri/ 2>/dev/null && {
                            log "      ✓ $dri"
                            dri_added=1
                        }
                    fi
                done
                ;;

            amd)
                # AMD has multiple DRI drivers for different generations
                # radeonsi: modern AMD GPUs (GCN+, Radeon Vega, AMD Ryzen APU)
                # r600: legacy AMD (HD 2000-7000)
                # r300: very old AMD (pre-HD)
                for dri in radeonsi_dri.so r600_dri.so r300_dri.so; do
                    if [ -f /usr/lib/x86_64-linux-gnu/dri/$dri ]; then
                        cp -L /usr/lib/x86_64-linux-gnu/dri/$dri \
                            usr/lib/x86_64-linux-gnu/dri/ 2>/dev/null && {
                            log "      ✓ $dri"
                            dri_added=1
                        }
                    fi
                done
                ;;

            universal)
                log "      (using base software DRI only - swrast/kms_swrast)"
                ;;
        esac

        if [ $dri_added -eq 0 ] && [ "$variant" != "universal" ]; then
            log "      ! No DRI drivers found for $variant (will use software rendering)"
        fi

        #Copy DRI driver dependencies
        # DRI drivers have many dependencies (Mesa, libdrm, libglapi, etc.)
        if [ $dri_added -gt 0 ]; then
            log "    Copying DRI driver dependencies..."
            find usr/lib/x86_64-linux-gnu/dri -name "*.so" -type f 2>/dev/null | while read dri_file; do
                dri_name=$(basename "$dri_file")
                host_dri="/usr/lib/x86_64-linux-gnu/dri/$dri_name"
                if [ -f "$host_dri" ]; then
                    ldd "$host_dri" 2>/dev/null | grep -o '/[^ ]*' | grep '\.so' | while read lib; do
                        if [ -f "$lib" ]; then
                            local rel_dir=$(dirname ".${lib}")
                            mkdir -p "$rel_dir" 2>/dev/null
                            if [ ! -f ".${lib}" ]; then
                                cp -L "$lib" ".${lib}" 2>/dev/null || true
                            fi
                        fi
                    done
                fi
            done
            log "      ✓ DRI dependencies copied"
        fi

        #Explicitly copy GPU-specific libdrm libraries
        # DRI drivers REQUIRE these GPU-specific libdrm libraries
        # Copy explicitly to ensure they're included even if ldd misses them
        case $variant in
            intel)
                log "    Copying Intel-specific libdrm..."
                if [ -f /usr/lib/x86_64-linux-gnu/libdrm_intel.so.1 ]; then
                    mkdir -p usr/lib/x86_64-linux-gnu
                    cp -L /usr/lib/x86_64-linux-gnu/libdrm_intel.so* \
                        usr/lib/x86_64-linux-gnu/ 2>/dev/null && {
                        log "      ✓ libdrm_intel.so.1"
                    }
                else
                    warn "      ! libdrm_intel.so.1 NOT found - Intel DRI may fail!"
                fi
                ;;

            amd)
                log "    Copying AMD-specific libdrm..."
                local amd_drm_ok=true

                if [ -f /usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1 ]; then
                    mkdir -p usr/lib/x86_64-linux-gnu
                    cp -L /usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so* \
                        usr/lib/x86_64-linux-gnu/ 2>/dev/null && {
                        log "      ✓ libdrm_amdgpu.so.1 (CRITICAL for AMD Ryzen APU)"
                    }
                else
                    warn "      ! libdrm_amdgpu.so.1 NOT found - AMD Ryzen APU will FAIL!"
                    amd_drm_ok=false
                fi

                if [ -f /usr/lib/x86_64-linux-gnu/libdrm_radeon.so.1 ]; then
                    cp -L /usr/lib/x86_64-linux-gnu/libdrm_radeon.so* \
                        usr/lib/x86_64-linux-gnu/ 2>/dev/null && {
                        log "      ✓ libdrm_radeon.so.1 (legacy AMD)"
                    }
                else
                    warn "      ! libdrm_radeon.so.1 NOT found - legacy AMD will fail"
                fi

                if [ "$amd_drm_ok" = false ]; then
                    error "    ✗ CRITICAL: AMD DRM libraries missing - AMD variant will NOT work!"
                fi
                ;;

            vmware)
                log "    (VMware uses base libdrm only)"
                ;;

            universal)
                log "    (Universal uses base libdrm only)"
                ;;
        esac
    fi

    # Copy dependencies for added X.org drivers
    if [ $xorg_added -eq 1 ]; then
        log "    Copying driver dependencies..."
        find usr/lib/xorg/modules/drivers -name "*.so" -type f 2>/dev/null | while read drv; do
            ldd "$drv" 2>/dev/null | grep -o '/[^ ]*' | grep '\.so' | while read lib; do
                if [ -f "$lib" ]; then
                    local rel_dir=$(dirname ".${lib}")
                    mkdir -p "$rel_dir" 2>/dev/null
                    if [ ! -f ".${lib}" ]; then
                        cp -L "$lib" ".${lib}" 2>/dev/null || true
                    fi
                fi
            done
        done
    fi

    # Update init to load correct modules
    if [ -f init ]; then
        # Convert array to space-separated string for sed
        local modules_str="${kernel_modules[*]}"
        # Add module loading before X starts
        sed -i "/# Graphics drivers/a\\
for drv in $modules_str; do /sbin/modprobe \\\$drv 2>/dev/null || true; done" init
    fi

    # Package
    local output_file="$OUTPUT_DIR/initrd-${variant}.img"

    # Use selected compression algorithm (default: zstd -19 -T0 -c)
    local compression_cmd="${COMPRESSION_CMD:-zstd -19 -T0 -c}"
    local algo_name="${COMPRESSION_ALGO:-zstd}"

    # Verify compression tool
    local comp_tool=$(echo "$compression_cmd" | awk '{print $1}')
    if ! command -v "$comp_tool" >/dev/null 2>&1; then
        error "Compression tool not found: $comp_tool"
        return 1
    fi

    log ""
    log "  Compressing with $algo_name..."
    log "  Command: $compression_cmd"
    log "  Output: initrd-${variant}.img"
    log "  This will take ~5-30 seconds..."

    local start_time=$(date +%s)

    # Compress with proper error handling (disable pipefail temporarily)
    set +e
    find . | cpio --quiet -H newc -o 2>/dev/null | $compression_cmd > "$output_file" 2>/dev/null
    local compress_status=$?
    set -e

    if [ $compress_status -ne 0 ]; then
        error "Failed to package $variant variant (exit code: $compress_status)"
        error "Compression command: $compression_cmd"
        error "Output file: $output_file"
        return 1
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Verify output file was created and has reasonable size
    if [ ! -f "$output_file" ]; then
        error "Output file not created: $output_file"
        return 1
    fi

    local file_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "0")
    if [ "$file_size" -lt 10000000 ]; then
        error "Output file too small: $file_size bytes (expected >10MB)"
        error "Something went wrong with compression"
        return 1
    fi

    local size=$(du -h "$output_file" | cut -f1)
    log ""
    log "✓ GPU variant ${variant^^} created successfully!"
    log "  Image: initrd-${variant}.img"
    log "  Size: $size"
    log "  Drivers: $driver_count"
    log "  Time: ${duration}s"

    return 0
}

# ============================================
# VALIDATE VARIANT
# ============================================
validate_variant() {
    local variant=$1
    local output_file=$2

    log ""
    log "  Validating $variant variant..."

    local validation_failed=false

    # ============================================
    # VALIDATE IMAGE FILE
    # ============================================
    if [ ! -f "$output_file" ]; then
        error "    ✗ Output file missing: $output_file"
        return 1
    fi

    local file_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null || echo "0")
    local file_size_mb=$((file_size / 1024 / 1024))

    # Check minimum size (should be at least 100MB)
    if [ "$file_size_mb" -lt 100 ]; then
        error "    ✗ Image file too small: ${file_size_mb}MB (expected >100MB)"
        validation_failed=true
    else
        log "    ✓ Image size: ${file_size_mb}MB"
    fi

    # ============================================
    # EXTRACT AND VALIDATE CONTENTS
    # ============================================
    local temp_validate_dir="/tmp/validate-$$-$variant"
    mkdir -p "$temp_validate_dir"
    cd "$temp_validate_dir"

    log "    Extracting image for validation..."

    # Use decompression command
    local decompress_cmd="${DECOMPRESSION_CMD:-zstd -dc}"
    set +e
    $decompress_cmd "$output_file" 2>/dev/null | cpio -idm 2>/dev/null
    local extract_status=$?
    set -e

    if [ $extract_status -ne 0 ]; then
        error "    ✗ Failed to extract image for validation"
        cd /
        rm -rf "$temp_validate_dir"
        return 1
    fi

    # ============================================
    # VALIDATE VARIANT-SPECIFIC COMPONENTS
    # ============================================
    case $variant in
        intel)
            log "    Checking Intel-specific components..."

            # Check kernel module directory
            local kernel_ver=$(uname -r)
            if [ ! -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915" ]; then
                error "      ✗ Intel i915 kernel module directory missing"
                validation_failed=true
            else
                local module_count=$(find "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915" -name "*.ko" 2>/dev/null | wc -l)
                log "      ✓ Intel i915 kernel modules: $module_count files"
            fi

            # Check X.org driver (optional - can use modesetting)
            if [ -f "usr/lib/xorg/modules/drivers/intel_drv.so" ]; then
                log "      ✓ intel_drv.so present"
            else
                log "      ℹ intel_drv.so not present (will use modesetting - OK)"
            fi

            # Check firmware (CRITICAL)
            if [ ! -d "lib/firmware/i915" ]; then
                error "      ✗ Intel i915 firmware directory missing (CRITICAL!)"
                validation_failed=true
            else
                local fw_count=$(find "lib/firmware/i915" -type f 2>/dev/null | wc -l)
                local fw_size_kb=$(du -sk "lib/firmware/i915" 2>/dev/null | awk '{print $1}')
                local fw_size_mb=$((fw_size_kb / 1024))

                # Debian 12 has ~115 files, ~15MB (firmware-linux-nonfree 20230210-5)
                if [ "$fw_count" -lt 100 ]; then
                    error "      ✗ Insufficient i915 firmware files: $fw_count (expected >100)"
                    validation_failed=true
                elif [ "$fw_size_mb" -lt 10 ]; then
                    error "      ✗ i915 firmware too small: ${fw_size_mb}MB (expected >10MB)"
                    validation_failed=true
                else
                    log "      ✓ Intel i915 firmware: $fw_count files, ${fw_size_mb}MB"
                fi
            fi

            # Check libdrm
            if [ ! -f "usr/lib/x86_64-linux-gnu/libdrm_intel.so.1" ]; then
                error "      ✗ libdrm_intel.so.1 missing (CRITICAL!)"
                validation_failed=true
            else
                log "      ✓ libdrm_intel.so.1 present"
            fi

            # Check DRI drivers
            local dri_found=false
            if [ -f "usr/lib/x86_64-linux-gnu/dri/i965_dri.so" ] || \
               [ -f "usr/lib/x86_64-linux-gnu/dri/iris_dri.so" ]; then
                dri_found=true
                log "      ✓ Intel DRI drivers present"
            fi

            if [ "$dri_found" = false ]; then
                error "      ✗ No Intel DRI drivers found (hardware acceleration will fail)"
                validation_failed=true
            fi
            ;;

        amd)
            log "    Checking AMD-specific components..."

            # Check kernel modules
            local kernel_ver=$(uname -r)
            local amd_modules_found=false

            if [ -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd" ]; then
                local module_count=$(find "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd" -name "*.ko" 2>/dev/null | wc -l)
                log "      ✓ AMD amdgpu kernel modules: $module_count files"
                amd_modules_found=true
            fi

            if [ -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/radeon" ]; then
                local module_count=$(find "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/radeon" -name "*.ko" 2>/dev/null | wc -l)
                log "      ✓ AMD radeon kernel modules: $module_count files"
                amd_modules_found=true
            fi

            if [ "$amd_modules_found" = false ]; then
                error "      ✗ No AMD kernel modules found"
                validation_failed=true
            fi

            # Check X.org driver (should use modesetting from base)
            if [ -f "usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
                log "      ✓ modesetting_drv.so present (correct for AMD)"
            else
                error "      ✗ modesetting_drv.so missing (AMD uses modesetting+KMS)"
                validation_failed=true
            fi

            # Check firmware (CRITICAL)
            if [ ! -d "lib/firmware/amdgpu" ]; then
                error "      ✗ AMD amdgpu firmware directory missing (CRITICAL!)"
                validation_failed=true
            else
                local fw_count=$(find "lib/firmware/amdgpu" -type f 2>/dev/null | wc -l)
                local fw_size_kb=$(du -sk "lib/firmware/amdgpu" 2>/dev/null | awk '{print $1}')
                local fw_size_mb=$((fw_size_kb / 1024))

                # Debian 12 has ~530 files, ~60MB (firmware-amd-graphics 20230210-5)
                if [ "$fw_count" -lt 500 ]; then
                    error "      ✗ Insufficient amdgpu firmware files: $fw_count (expected >500)"
                    validation_failed=true
                elif [ "$fw_size_mb" -lt 50 ]; then
                    error "      ✗ amdgpu firmware too small: ${fw_size_mb}MB (expected >50MB)"
                    validation_failed=true
                else
                    log "      ✓ AMD amdgpu firmware: $fw_count files, ${fw_size_mb}MB"
                fi
            fi

            # Check libdrm (CRITICAL)
            if [ ! -f "usr/lib/x86_64-linux-gnu/libdrm_amdgpu.so.1" ]; then
                error "      ✗ libdrm_amdgpu.so.1 missing (CRITICAL!)"
                validation_failed=true
            else
                log "      ✓ libdrm_amdgpu.so.1 present"
            fi

            # Check DRI drivers
            if [ ! -f "usr/lib/x86_64-linux-gnu/dri/radeonsi_dri.so" ]; then
                error "      ✗ radeonsi_dri.so missing (AMD Ryzen APU needs this!)"
                validation_failed=true
            else
                log "      ✓ radeonsi_dri.so present"
            fi
            ;;

        vmware)
            log "    Checking VMware-specific components..."

            # Check kernel module
            local kernel_ver=$(uname -r)
            if [ ! -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx" ]; then
                error "      ✗ VMware vmwgfx kernel module directory missing"
                validation_failed=true
            else
                local module_count=$(find "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx" -name "*.ko" 2>/dev/null | wc -l)
                log "      ✓ VMware vmwgfx kernel modules: $module_count files"
            fi

            # Check X.org driver
            if [ ! -f "usr/lib/xorg/modules/drivers/vmware_drv.so" ]; then
                error "      ✗ vmware_drv.so missing"
                validation_failed=true
            else
                log "      ✓ vmware_drv.so present"
            fi

            # Check DRI driver
            if [ ! -f "usr/lib/x86_64-linux-gnu/dri/vmwgfx_dri.so" ]; then
                error "      ✗ vmwgfx_dri.so missing"
                validation_failed=true
            else
                log "      ✓ vmwgfx_dri.so present"
            fi

            # VMware doesn't need firmware (virtual GPU)
            log "      ℹ Firmware not required for VMware (virtual GPU)"
            ;;

        universal)
            log "    Checking Universal variant components..."

            # Universal should have ONLY base drivers
            if [ -d "lib/firmware/i915" ] || [ -d "lib/firmware/amdgpu" ]; then
                warn "      ⚠ Found GPU firmware in Universal variant (should not be present)"
            else
                log "      ✓ No GPU firmware (correct for Universal)"
            fi

            local kernel_ver=$(uname -r)
            if [ -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/i915" ] || \
               [ -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/amd" ] || \
               [ -d "lib/modules/$kernel_ver/kernel/drivers/gpu/drm/vmwgfx" ]; then
                warn "      ⚠ Found GPU kernel modules in Universal variant (should not be present)"
            else
                log "      ✓ No GPU kernel modules (correct for Universal)"
            fi

            # Check base drivers
            if [ ! -f "usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
                error "      ✗ modesetting_drv.so missing (base driver)"
                validation_failed=true
            else
                log "      ✓ modesetting_drv.so present"
            fi

            if [ ! -f "usr/lib/xorg/modules/drivers/vesa_drv.so" ]; then
                error "      ✗ vesa_drv.so missing (fallback driver)"
                validation_failed=true
            else
                log "      ✓ vesa_drv.so present"
            fi
            ;;
    esac

    # ============================================
    # VALIDATE COMMON COMPONENTS (ALL VARIANTS)
    # ============================================
    log "    Checking common components..."

    # Check init script
    if [ ! -f "init" ]; then
        error "      ✗ init script missing"
        validation_failed=true
    else
        log "      ✓ init script present"
    fi

    # Check modesetting driver (fallback for all variants)
    if [ ! -f "usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
        error "      ✗ modesetting_drv.so missing (fallback driver)"
        validation_failed=true
    fi

    # Check input drivers
    local input_drivers_ok=false
    if [ -f "usr/lib/xorg/modules/input/libinput_drv.so" ] || \
       [ -f "usr/lib/xorg/modules/input/evdev_drv.so" ]; then
        input_drivers_ok=true
        log "      ✓ Input drivers present"
    else
        error "      ✗ No input drivers found (mouse/keyboard will not work!)"
        validation_failed=true
    fi

    # Cleanup
    cd /
    rm -rf "$temp_validate_dir"

    # ============================================
    # VALIDATION RESULT
    # ============================================
    if [ "$validation_failed" = true ]; then
        error "  ✗ VALIDATION FAILED for $variant variant"
        error "  Image may not work correctly on thin clients!"
        return 1
    fi

    log "  ✓ Validation PASSED for $variant variant"
    return 0
}

# ============================================
# MAIN
# ============================================
main() {
    ensure_dir "$OUTPUT_DIR" 755

    # Create base image
    create_base_image || exit 1

    # Build variants
    log ""
    log "════════════════════════════════════════════════════════════════"
    log "Building GPU-specific variants (4 total)..."
    log "════════════════════════════════════════════════════════════════"

    local total_variants=4
    local start_all=$(date +%s)

    log ""
    log "[1/$total_variants] VMware variant..."
    if add_video_variant "vmware"; then
        validate_variant "vmware" "$OUTPUT_DIR/initrd-vmware.img" || warn "VMware variant validation failed"
    else
        warn "VMware variant build failed"
    fi

    log ""
    log "[2/$total_variants] Intel variant..."
    if add_video_variant "intel"; then
        validate_variant "intel" "$OUTPUT_DIR/initrd-intel.img" || warn "Intel variant validation failed"
    else
        warn "Intel variant build failed"
    fi

    log ""
    log "[3/$total_variants] AMD variant (Ryzen APU)..."
    if add_video_variant "amd"; then
        validate_variant "amd" "$OUTPUT_DIR/initrd-amd.img" || warn "AMD variant validation failed"
    else
        warn "AMD variant build failed"
    fi

    log ""
    log "[4/$total_variants] Universal variant (fallback)..."
    if add_video_variant "universal"; then
        validate_variant "universal" "$OUTPUT_DIR/initrd-universal.img" || warn "Universal variant validation failed"
    else
        warn "Universal variant build failed"
    fi

    local end_all=$(date +%s)
    local total_time=$((end_all - start_all))

    #Create 'fallback' symlink to universal
    # Fallback variant is universal (software rendering)
    # Note: "autodetect" logic runs in init script when using GPU variants
    log ""
    log "Creating fallback variant (symlink to universal)..."
    cd "$OUTPUT_DIR"
    if [ -f "initrd-universal.img" ]; then
        ln -sf "initrd-universal.img" "initrd-fallback.img"
        log "  ✓ initrd-fallback.img -> initrd-universal.img"

        # Keep backward compatibility with old "autodetect" name
        ln -sf "initrd-universal.img" "initrd-autodetect.img"
        log "  ✓ initrd-autodetect.img -> initrd-universal.img (legacy compatibility)"
    else
        warn "  ! Universal image not found, skipping fallback"
    fi

    # Cleanup
    rm -rf "$WORK_DIR"

    log ""
    log "════════════════════════════════════════════════════════════════"
    log "✓ ALL INITRAMFS VARIANTS CREATED SUCCESSFULLY"
    log "════════════════════════════════════════════════════════════════"
    log ""
    log "Available variants:"
    log "  1. initrd-minimal.img    - Base image (no GPU drivers)"
    log "  2. initrd-vmware.img     - VMware ESXi/Workstation (vmwgfx)"
    log "  3. initrd-intel.img      - Intel HD/Iris Graphics (i915 + firmware)"
    log "  4. initrd-amd.img        - AMD Ryzen APU (amdgpu + firmware)"
    log "  5. initrd-universal.img  - Universal fallback (software rendering)"
    log "  6. initrd-fallback.img   - Symlink to universal (clearer naming)"
    log "  7. initrd-autodetect.img - Legacy symlink to universal (backward compat)"
    log ""
    log "Total time: ${total_time}s"
    log "Compression: ${COMPRESSION_ALGO:-zstd}"
    log ""
    log "Available images:"
    log ""
    ls -lh "$OUTPUT_DIR"/initrd-*.img | awk '{printf "  %-25s %6s\n", $9, $5}'
    log ""

    return 0
}

main "$@"
