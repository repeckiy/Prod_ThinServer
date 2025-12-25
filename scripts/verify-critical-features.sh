#!/bin/bash

################################################################################
# Thin-Server ThinClient Manager - Critical Features Verification Script
# Version: 1.0.0
# Date: 2025-10-23
#
# Purpose: Verify critical features added in recent updates:
#   - SSH Server (Dropbear) functionality
#   - RDP parameter parsing and usage (sound, printer, USB, resolution)
#   - Critical libraries for Debian 12 (libbpf.so.1, ALSA, etc.)
#   - Binary dependencies completeness
#   - File permissions and executability
#
# This script complements verify-installation.sh with deep feature validation
################################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Configuration
INITRAMFS_PATH="${INITRAMFS_PATH:-/var/www/thinclient/initrds/initrd-minimal.img}"
EXTRACT_DIR=""
CLEANUP_ON_EXIT=true

################################################################################
# Helper Functions
################################################################################

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}  ✓${NC} $*"
    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

error() {
    echo -e "${RED}  ✗${NC} $*"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

warning() {
    echo -e "${YELLOW}  ⚠${NC} $*"
    WARNING_CHECKS=$((WARNING_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
}

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

################################################################################
# Initramfs Extraction
################################################################################

extract_initramfs() {
    section "EXTRACTING INITRAMFS FOR ANALYSIS"

    if [ ! -f "$INITRAMFS_PATH" ]; then
        error "Initramfs not found at: $INITRAMFS_PATH"
        exit 1
    fi

    log "Initramfs: $INITRAMFS_PATH"
    log "Size: $(du -h "$INITRAMFS_PATH" | cut -f1)"

    # Determine decompression command from config
    DECOMPRESS_CMD="gunzip"
    if [ -f /opt/thin-server/config.env ]; then
        source /opt/thin-server/config.env
        DECOMPRESS_CMD="${DECOMPRESSION_CMD:-gunzip}"
    fi
    log "Decompression: $DECOMPRESS_CMD"

    EXTRACT_DIR=$(mktemp -d)
    log "Extracting to: $EXTRACT_DIR"

    cd "$EXTRACT_DIR"
    if $DECOMPRESS_CMD < "$INITRAMFS_PATH" | cpio -idm 2>/dev/null; then
        success "Initramfs extracted successfully"
    else
        error "Failed to extract initramfs"
        log "Tried command: $DECOMPRESS_CMD < $INITRAMFS_PATH | cpio -idm"
        exit 1
    fi

    cd - > /dev/null
}

cleanup() {
    if [ "$CLEANUP_ON_EXIT" = true ] && [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ]; then
        log "Cleaning up: $EXTRACT_DIR"
        rm -rf "$EXTRACT_DIR"
    fi
}

trap cleanup EXIT

################################################################################
# Category 1: SSH Server Verification
################################################################################

verify_ssh_server() {
    section "CATEGORY 1: SSH SERVER (DROPBEAR) VERIFICATION"

    log "Checking Dropbear SSH server components..."

    # 1.1 - Dropbear binary
    if [ -f "$EXTRACT_DIR/usr/sbin/dropbear" ]; then
        if [ -x "$EXTRACT_DIR/usr/sbin/dropbear" ]; then
            success "Dropbear SSH server binary present and executable"
        else
            error "Dropbear binary exists but NOT EXECUTABLE"
        fi
    else
        error "Dropbear SSH server binary MISSING"
    fi

    # 1.2 - Dropbearkey for host key generation
    if [ -f "$EXTRACT_DIR/usr/bin/dropbearkey" ]; then
        if [ -x "$EXTRACT_DIR/usr/bin/dropbearkey" ]; then
            success "Dropbearkey (host key generator) present and executable"
        else
            error "Dropbearkey exists but NOT EXECUTABLE"
        fi
    else
        error "Dropbearkey binary MISSING"
    fi

    # 1.3 - Dropbear dependencies
    log "Checking Dropbear dependencies..."
    if [ -f "/usr/sbin/dropbear" ]; then
        MISSING_DEPS=0
        while IFS= read -r lib; do
            if [ -n "$lib" ] && [ "$lib" != "not" ]; then
                libname=$(basename "$lib")
                if [ ! -f "$EXTRACT_DIR/$lib" ]; then
                    error "Dropbear dependency MISSING: $libname"
                    MISSING_DEPS=$((MISSING_DEPS + 1))
                fi
            fi
        done < <(ldd /usr/sbin/dropbear 2>/dev/null | grep "=>" | awk '{print $3}')

        if [ $MISSING_DEPS -eq 0 ]; then
            success "All Dropbear dependencies present"
        fi
    else
        warning "Cannot check Dropbear dependencies (dropbear not in host system)"
    fi

    # 1.4 - Shadow file with password hash
    if [ -f "$EXTRACT_DIR/etc/shadow" ]; then
        # Read the actual shadow content for debugging
        local shadow_content=$(cat "$EXTRACT_DIR/etc/shadow" 2>/dev/null)
        local root_line=$(grep "^root:" "$EXTRACT_DIR/etc/shadow" 2>/dev/null || echo "")

        if [ -z "$root_line" ]; then
            error "Shadow file exists but NO root entry found"
            echo "    Shadow file content (first 200 chars): ${shadow_content:0:200}"
        else
            # Extract password hash field (between first and second colon)
            local hash_field=$(echo "$root_line" | cut -d: -f2)

            # Check if hash is present and starts with $6$ (SHA-512)
            if [ -z "$hash_field" ] || [ "$hash_field" = "!" ] || [ "$hash_field" = "*" ]; then
                error "Shadow file has root entry but NO PASSWORD SET"
                echo "    Root line: ${root_line:0:100}"
            elif [[ "$hash_field" =~ ^\$6\$ ]]; then
                success "Shadow file with root password hash (SHA-512) present"
                echo "    Hash prefix: ${hash_field:0:20}..."
            elif [[ "$hash_field" =~ ^\$5\$ ]]; then
                warning "Shadow file has SHA-256 hash (expected SHA-512)"
                echo "    Hash prefix: ${hash_field:0:20}..."
            elif [[ "$hash_field" =~ ^\$1\$ ]]; then
                warning "Shadow file has MD5 hash (expected SHA-512)"
                echo "    Hash prefix: ${hash_field:0:20}..."
            else
                error "Shadow file has root password but UNKNOWN HASH FORMAT"
                echo "    Hash prefix: ${hash_field:0:30}..."
            fi
        fi
    else
        error "Shadow file (/etc/shadow) MISSING"
    fi

    # 1.5 - Dropbear directory structure
    if [ -d "$EXTRACT_DIR/etc/dropbear" ]; then
        success "Dropbear configuration directory (/etc/dropbear) present"
    else
        warning "Dropbear configuration directory missing (will be created at runtime)"
    fi

    # 1.6 - Init script SSH startup code
    INIT_SCRIPT="$EXTRACT_DIR/init"
    if [ -f "$INIT_SCRIPT" ]; then
        if grep -q "dropbear -F -E -p 22" "$INIT_SCRIPT"; then
            success "Init script contains SSH server startup code"
        else
            error "SSH server startup code MISSING in init script"
        fi

        if grep -q "/usr/bin/dropbearkey" "$INIT_SCRIPT"; then
            success "Init script contains host key generation code"
        else
            warning "Host key generation code not found in init (may use pre-generated keys)"
        fi
    else
        error "Init script NOT FOUND"
    fi
}

################################################################################
# Category 2: RDP Parameter Verification
################################################################################

verify_rdp_parameters() {
    section "CATEGORY 2: RDP PARAMETER PARSING AND USAGE"

    INIT_SCRIPT="$EXTRACT_DIR/init"

    if [ ! -f "$INIT_SCRIPT" ]; then
        error "Init script NOT FOUND - cannot verify RDP parameters"
        return
    fi

    log "Checking RDP parameter PARSING in init script..."

    # 2.1 - Parameter parsing in case statement
    PARAMS=("sound=" "printer=" "usb=" "resolution=" "videodriver=")
    for param in "${PARAMS[@]}"; do
        if grep -q "${param}\*)" "$INIT_SCRIPT"; then
            success "Parameter '${param}' is PARSED in init script"
        else
            error "CRITICAL: Parameter '${param}' NOT PARSED in init script"
        fi
    done

    log "Checking RDP parameter USAGE in xfreerdp command..."

    # 2.2 - Sound parameter usage
    if grep -q "/sound:sys:alsa" "$INIT_SCRIPT"; then
        success "Sound parameter USED in xfreerdp command (/sound:sys:alsa)"
    else
        error "CRITICAL: Sound parameter NOT USED in xfreerdp"
    fi

    # 2.3 - Printer parameter usage
    if grep -q "/printer" "$INIT_SCRIPT"; then
        success "Printer parameter USED in xfreerdp command (/printer)"
    else
        error "CRITICAL: Printer parameter NOT USED in xfreerdp"
    fi

    # 2.4 - USB parameter usage
    if grep -q "/usb:id,dev" "$INIT_SCRIPT"; then
        success "USB redirection parameter USED in xfreerdp (/usb:id,dev:*)"
    else
        error "CRITICAL: USB parameter NOT USED in xfreerdp"
    fi

    # 2.5 - Resolution/Display mode parameter usage
    # Thin-Server uses fullscreen mode (/f) by design for reliability
    if grep -q "CMD_ARGS=.*\/f" "$INIT_SCRIPT" || grep -q '"/f"' "$INIT_SCRIPT"; then
        success "Display mode configured: fullscreen (/f) - reliable for thin clients"
    elif grep -q "/size:" "$INIT_SCRIPT" || grep -q "/w:" "$INIT_SCRIPT"; then
        success "Display mode configured: custom resolution (/size: or /w:/h:)"
    else
        error "CRITICAL: No display mode configured in xfreerdp"
    fi

    # 2.6 - Default values set
    if grep -q 'SOUND_ENABLED:=' "$INIT_SCRIPT"; then
        success "Default values set for RDP parameters"
    else
        warning "Default values may not be set for RDP parameters"
    fi

    log "Checking conditional parameter building..."

    # 2.7 - Conditional logic for sound
    if grep -q 'if.*SOUND_ENABLED.*yes' "$INIT_SCRIPT"; then
        success "Conditional logic for sound parameter present"
    else
        warning "Conditional logic for sound may be missing"
    fi

    # 2.8 - Conditional logic for printer
    if grep -q 'if.*PRINTER_ENABLED.*yes' "$INIT_SCRIPT"; then
        success "Conditional logic for printer parameter present"
    else
        warning "Conditional logic for printer may be missing"
    fi

    # 2.9 - Conditional logic for USB (variable name: USB_REDIRECT)
    if grep -q 'if.*USB_REDIRECT.*yes' "$INIT_SCRIPT"; then
        success "Conditional logic for USB parameter present"
    else
        warning "Conditional logic for USB may be missing"
    fi
}

################################################################################
# Category 3: Critical Libraries Verification
################################################################################

verify_critical_libraries() {
    section "CATEGORY 3: CRITICAL LIBRARIES (DEBIAN 12)"

    log "Checking Debian 12 critical libraries..."

    # 3.1 - libbpf.so.1 (CRITICAL for Debian 12)
    if find "$EXTRACT_DIR" -name "libbpf.so.1" 2>/dev/null | grep -q .; then
        success "libbpf.so.1 found (Debian 12 required for 'ip' command)"
    else
        error "CRITICAL: libbpf.so.1 MISSING - 'ip' command will FAIL!"
    fi

    # Check for old version (should NOT be present)
    if find "$EXTRACT_DIR" -name "libbpf.so.0" 2>/dev/null | grep -q .; then
        warning "Old libbpf.so.0 found (should be .so.1 for Debian 12)"
    fi

    # 3.2 - OpenSSL 3.x libraries
    if find "$EXTRACT_DIR" -name "libssl.so.3" 2>/dev/null | grep -q .; then
        success "libssl.so.3 found (OpenSSL 3.x)"
    else
        error "libssl.so.3 MISSING (required for RDP TLS)"
    fi

    if find "$EXTRACT_DIR" -name "libcrypto.so.3" 2>/dev/null | grep -q .; then
        success "libcrypto.so.3 found (OpenSSL 3.x)"
    else
        error "libcrypto.so.3 MISSING"
    fi

    log "Checking ALSA sound libraries..."

    # 3.3 - ALSA libraries for sound support
    if find "$EXTRACT_DIR" -name "libasound.so.2*" 2>/dev/null | grep -q .; then
        success "libasound.so.2 found (ALSA sound support)"
    else
        error "libasound.so.2 MISSING (required for /sound:sys:alsa)"
    fi

    # Check for ALSA configuration in multiple locations
    ALSA_CONF_FOUND=false
    for alsa_path in "usr/share/alsa/alsa.conf" "etc/alsa/alsa.conf" "usr/share/alsa.conf"; do
        if [ -f "$EXTRACT_DIR/$alsa_path" ]; then
            success "ALSA configuration found at: $alsa_path"
            ALSA_CONF_FOUND=true
            break
        fi
    done

    if [ "$ALSA_CONF_FOUND" = false ]; then
        warning "ALSA configuration not found (sound may still work with defaults)"
    fi

    log "Checking USB redirection libraries..."

    # 3.4 - USB libraries
    if find "$EXTRACT_DIR" -name "libusb-1.0.so*" 2>/dev/null | grep -q .; then
        success "libusb-1.0 found (USB redirection support)"
    else
        error "libusb-1.0 MISSING (required for /usb:id,dev:*)"
    fi

    log "Checking core system libraries..."

    # 3.5 - Core libraries
    CORE_LIBS=("libc.so.6" "libm.so.6" "libpthread.so.0" "libdl.so.2")
    for lib in "${CORE_LIBS[@]}"; do
        if find "$EXTRACT_DIR" -name "$lib" 2>/dev/null | grep -q .; then
            success "$lib present"
        else
            error "$lib MISSING"
        fi
    done

    # 3.6 - X11 libraries
    if find "$EXTRACT_DIR" -name "libX11.so.6" 2>/dev/null | grep -q .; then
        success "libX11.so.6 found (X Window System)"
    else
        error "libX11.so.6 MISSING (required for X.org)"
    fi

    if find "$EXTRACT_DIR" -name "libGL.so.1" 2>/dev/null | grep -q .; then
        success "libGL.so.1 found (OpenGL)"
    else
        warning "libGL.so.1 missing (may affect graphics performance)"
    fi
}

################################################################################
# Category 4: Binary Dependencies Verification
################################################################################

verify_binary_dependencies() {
    section "CATEGORY 4: BINARY DEPENDENCIES COMPLETENESS"

    log "Checking xfreerdp dependencies..."

    # Try to use xfreerdp from host, if not available skip check
    XFREERDP_FOR_LDD=""
    if [ -f "/usr/bin/xfreerdp" ]; then
        XFREERDP_FOR_LDD="/usr/bin/xfreerdp"
    elif [ -f "/usr/local/bin/xfreerdp" ]; then
        XFREERDP_FOR_LDD="/usr/local/bin/xfreerdp"
    fi

    if [ -n "$XFREERDP_FOR_LDD" ]; then
        log "  Using xfreerdp from: $XFREERDP_FOR_LDD"
        MISSING_COUNT=0
        TOTAL_DEPS=0

        while IFS= read -r lib; do
            if [ -n "$lib" ] && [ "$lib" != "not" ]; then
                TOTAL_DEPS=$((TOTAL_DEPS + 1))
                libname=$(basename "$lib")
                if [ ! -f "$EXTRACT_DIR/$lib" ]; then
                    error "xfreerdp dependency MISSING: $libname"
                    MISSING_COUNT=$((MISSING_COUNT + 1))
                fi
            fi
        done < <(LD_LIBRARY_PATH="/usr/local/lib:${LD_LIBRARY_PATH:-}" ldd "$XFREERDP_FOR_LDD" 2>/dev/null | grep "=>" | awk '{print $3}')

        if [ $TOTAL_DEPS -eq 0 ]; then
            warning "Could not determine xfreerdp dependencies (ldd failed)"
        elif [ $MISSING_COUNT -eq 0 ]; then
            success "All xfreerdp dependencies present in initramfs ($TOTAL_DEPS checked)"
        fi
    else
        log "  xfreerdp not in /usr/bin or /usr/local/bin"
        log "  Checking if xfreerdp exists in initramfs..."
        if [ -f "$EXTRACT_DIR/usr/bin/xfreerdp" ]; then
            success "xfreerdp binary found in initramfs"
            log "  Note: Cannot verify dependencies from extracted binary"
        else
            warning "Cannot check xfreerdp dependencies (binary not found)"
        fi
    fi

    log "Checking Xorg dependencies..."
    if [ -f "/usr/lib/xorg/Xorg" ]; then
        MISSING_COUNT=0
        while IFS= read -r lib; do
            if [ -n "$lib" ] && [ "$lib" != "not" ]; then
                libname=$(basename "$lib")
                if [ ! -f "$EXTRACT_DIR/$lib" ]; then
                    error "Xorg dependency MISSING: $libname"
                    MISSING_COUNT=$((MISSING_COUNT + 1))
                fi
            fi
        done < <(ldd /usr/lib/xorg/Xorg 2>/dev/null | grep "=>" | awk '{print $3}')

        if [ $MISSING_COUNT -eq 0 ]; then
            success "All Xorg dependencies present in initramfs"
        fi
    else
        warning "Cannot check Xorg dependencies (not in host system)"
    fi

    log "Checking 'ip' command dependencies (libbpf.so.1 critical)..."
    if [ -f "/bin/ip" ] || [ -f "/sbin/ip" ]; then
        IP_BIN=$(which ip 2>/dev/null || echo "/bin/ip")
        if ldd "$IP_BIN" 2>/dev/null | grep -q "libbpf.so.1"; then
            if find "$EXTRACT_DIR" -name "libbpf.so.1" 2>/dev/null | grep -q .; then
                success "'ip' command requires libbpf.so.1 - PRESENT in initramfs"
            else
                error "CRITICAL: 'ip' requires libbpf.so.1 but it's MISSING from initramfs"
            fi
        else
            warning "'ip' command doesn't require libbpf.so.1 on this system"
        fi
    fi
}

################################################################################
# Category 5: File Permissions and Executability
################################################################################

verify_permissions() {
    section "CATEGORY 5: FILE PERMISSIONS AND EXECUTABILITY"

    log "Checking init script..."
    if [ -f "$EXTRACT_DIR/init" ]; then
        if [ -x "$EXTRACT_DIR/init" ]; then
            success "Init script is EXECUTABLE"
        else
            error "CRITICAL: Init script exists but NOT EXECUTABLE"
        fi
    else
        error "Init script MISSING"
    fi

    log "Checking critical binaries executability..."

    BINARIES=(
        "usr/bin/xfreerdp:FreeRDP client"
        "usr/lib/xorg/Xorg:X.org server"
        "usr/sbin/dropbear:SSH server"
        "usr/bin/dropbearkey:SSH key generator"
        "bin/ip:Network configuration"
        "bin/busybox:Core utilities"
        "usr/sbin/ntpdate:NTP time sync"
    )

    for entry in "${BINARIES[@]}"; do
        bin="${entry%%:*}"
        desc="${entry##*:}"

        if [ -f "$EXTRACT_DIR/$bin" ]; then
            if [ -x "$EXTRACT_DIR/$bin" ]; then
                success "$desc ($bin) is executable"
            else
                error "$desc ($bin) exists but NOT EXECUTABLE"
            fi
        else
            error "$desc ($bin) MISSING"
        fi
    done

    log "Checking for broken symlinks..."
    BROKEN_COUNT=$(find "$EXTRACT_DIR" -xtype l 2>/dev/null | wc -l)
    if [ "$BROKEN_COUNT" -eq 0 ]; then
        success "No broken symlinks found"
    else
        warning "$BROKEN_COUNT broken symlinks found in initramfs"
        find "$EXTRACT_DIR" -xtype l 2>/dev/null | head -5 | while read -r link; do
            echo "    - ${link#$EXTRACT_DIR/}"
        done
    fi
}

################################################################################
# Category 6: FreeRDP Feature Verification
################################################################################

verify_freerdp_features() {
    section "CATEGORY 6: FREERDP COMPILATION FEATURES"

    log "Checking FreeRDP version and features..."

    # Try to find xfreerdp binary (host or in initramfs)
    XFREERDP_BIN=""
    if [ -f "/usr/bin/xfreerdp" ]; then
        XFREERDP_BIN="/usr/bin/xfreerdp"
    elif [ -f "$EXTRACT_DIR/usr/bin/xfreerdp" ]; then
        XFREERDP_BIN="$EXTRACT_DIR/usr/bin/xfreerdp"
    fi

    if [ -n "$XFREERDP_BIN" ]; then
        # Get version
        FREERDP_VERSION=$($XFREERDP_BIN --version 2>&1 | head -1 || echo "unknown")
        if echo "$FREERDP_VERSION" | grep -q "3\.17"; then
            success "FreeRDP version: $FREERDP_VERSION"
        else
            warning "FreeRDP version: $FREERDP_VERSION (expected 3.17.x)"
        fi

        # Test actual command support instead of using strings
        log "Testing FreeRDP command options..."

        # Test /sound support
        if $XFREERDP_BIN /sound:sys:alsa /help 2>&1 | head -20 | grep -qi "sound"; then
            success "FreeRDP supports /sound option (ALSA capable)"
        else
            # Fallback: check for ALSA in help
            if $XFREERDP_BIN /help 2>&1 | grep -qi "alsa"; then
                success "FreeRDP compiled with ALSA sound support"
            else
                warning "FreeRDP may not have ALSA support (cannot confirm)"
            fi
        fi

        # Test /printer support
        if $XFREERDP_BIN /help 2>&1 | grep -qi "printer"; then
            success "FreeRDP supports /printer option"
        else
            warning "FreeRDP may not have printer support (cannot confirm)"
        fi

        # Test /usb support
        if $XFREERDP_BIN /help 2>&1 | grep -qiE "usb|urbdrc"; then
            success "FreeRDP supports /usb redirection option"
        else
            warning "FreeRDP may not have USB support (cannot confirm)"
        fi

        # Additional: check for relevant shared libraries in initramfs
        log "Verifying FreeRDP libraries in initramfs..."

        if find "$EXTRACT_DIR" -name "libfreerdp*" 2>/dev/null | grep -q .; then
            FREERDP_LIBS=$(find "$EXTRACT_DIR" -name "libfreerdp*.so*" 2>/dev/null | wc -l)
            success "FreeRDP libraries found in initramfs ($FREERDP_LIBS files)"
        else
            warning "FreeRDP libraries not found in initramfs"
        fi

    else
        warning "FreeRDP binary not found for feature testing"
        warning "This is normal if FreeRDP is installed to custom location"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  THIN-SERVER THINCLIENT MANAGER - CRITICAL FEATURES VERIFICATION"
    echo "  Version: 1.0.0"
    echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Extract initramfs
    extract_initramfs

    # Run verification categories
    verify_ssh_server
    verify_rdp_parameters
    verify_critical_libraries
    verify_binary_dependencies
    verify_permissions
    verify_freerdp_features

    # Summary
    section "VERIFICATION SUMMARY"

    echo ""
    echo "Total Checks:    $TOTAL_CHECKS"
    echo -e "${GREEN}Passed:${NC}          $PASSED_CHECKS"
    echo -e "${RED}Failed:${NC}          $FAILED_CHECKS"
    echo -e "${YELLOW}Warnings:${NC}        $WARNING_CHECKS"
    echo ""

    if [ $FAILED_CHECKS -eq 0 ]; then
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL CRITICAL CHECKS PASSED${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        exit 0
    else
        echo -e "${RED}════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  ✗ CRITICAL ISSUES FOUND: $FAILED_CHECKS${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        exit 1
    fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
