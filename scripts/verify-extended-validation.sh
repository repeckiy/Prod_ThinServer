#!/bin/bash

################################################################################
# Thin-Server ThinClient Manager - Extended Validation Script
# Version: 1.0.0
# Date: 2025-10-25
#
# Purpose: Extended validation for critical and important deployment components
#
# CRITICAL CHECKS (Priority 1):
#   1. Nginx Configuration Validation
#   2. FreeRDP Compilation Features
#   3. X.org Server Validation
#   4. TFTP Server Functional Test
#
# IMPORTANT CHECKS (Priority 2):
#   5. Initramfs /init Script Validation
#   6. Kernel Modules Verification
#   7. BusyBox Applets Check
#   8. Flask API Endpoints Test
#   9. Database Schema Validation
#
# This script complements verify-installation.sh and verify-critical-features.sh
################################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}$*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

################################################################################
# Initramfs Extraction
################################################################################

extract_initramfs() {
    section "EXTRACTING INITRAMFS FOR ANALYSIS"

    if [ ! -f "$INITRAMFS_PATH" ]; then
        error "Initramfs not found at: $INITRAMFS_PATH"
        return 1
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
        return 1
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
# CRITICAL CHECK 1: Nginx Configuration Validation
################################################################################

verify_nginx_config() {
    section "CRITICAL CHECK 1: NGINX CONFIGURATION VALIDATION"

    log "Checking Nginx installation..."

    # 1.1 - Nginx binary exists
    if command -v nginx >/dev/null 2>&1; then
        local nginx_version=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "unknown")
        success "Nginx installed: version $nginx_version"
    else
        error "Nginx binary NOT FOUND"
        return 1
    fi

    # 1.2 - Nginx configuration syntax test
    log "Testing Nginx configuration syntax..."
    if nginx -t 2>/dev/null; then
        success "Nginx configuration syntax is VALID"
    else
        error "Nginx configuration has SYNTAX ERRORS"
        log "Run 'nginx -t' for details"
        return 1
    fi

    # 1.3 - Thinclient site configuration exists
    if [ -f /etc/nginx/sites-available/thinclient ]; then
        success "Thinclient Nginx site configuration exists"
    else
        error "Thinclient Nginx configuration MISSING"
        return 1
    fi

    # 1.4 - Site is enabled
    if [ -L /etc/nginx/sites-enabled/thinclient ]; then
        success "Thinclient site is ENABLED"
    else
        error "Thinclient site is NOT enabled"
        return 1
    fi

    # 1.5 - Configuration has proxy_pass to Flask
    if grep -q "proxy_pass.*127.0.0.1:5000" /etc/nginx/sites-available/thinclient; then
        success "Nginx proxy_pass to Flask configured"
    else
        error "Nginx proxy_pass to Flask MISSING or WRONG"
        return 1
    fi

    # 1.6 - Static files location configured
    if grep -q "root.*thinclient" /etc/nginx/sites-available/thinclient; then
        success "Static files root configured"
    else
        warning "Static files root may not be configured"
    fi

    # 1.7 - Nginx is running
    if systemctl is-active --quiet nginx 2>/dev/null; then
        success "Nginx service is RUNNING"
    else
        error "Nginx service is NOT running"
        return 1
    fi

    # 1.8 - Nginx functional test
    log "Testing Nginx HTTP response..."
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        success "Nginx responding (HTTP $http_code)"
    else
        error "Nginx NOT responding correctly (HTTP $http_code)"
        return 1
    fi
}

################################################################################
# CRITICAL CHECK 2: FreeRDP Compilation Features
################################################################################

verify_freerdp_features() {
    section "CRITICAL CHECK 2: FREERDP COMPILATION FEATURES"

    log "Checking FreeRDP binary..."

    # 2.1 - FreeRDP binary exists
    if [ ! -f /usr/local/bin/xfreerdp ]; then
        error "FreeRDP binary NOT FOUND at /usr/local/bin/xfreerdp"
        return 1
    fi
    success "FreeRDP binary exists"

    # 2.2 - FreeRDP version check
    local freerdp_version=$(/usr/local/bin/xfreerdp --version 2>&1 | head -1 | grep -oP 'version \K[0-9.]+' || echo "unknown")
    if [[ "$freerdp_version" == 3.17.* ]]; then
        success "FreeRDP version: $freerdp_version (correct)"
    else
        warning "FreeRDP version: $freerdp_version (expected 3.17.x)"
    fi

    log "Checking FreeRDP compilation features via ldd..."

    # 2.3 - ALSA sound support
    if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libasound"; then
        success "FreeRDP compiled with ALSA sound support"
    else
        error "FreeRDP MISSING ALSA support (sound will NOT work)"
    fi

    # 2.4 - USB redirection support
    if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libusb"; then
        success "FreeRDP compiled with USB redirection support"
    else
        error "FreeRDP MISSING USB support (USB redirection will NOT work)"
    fi

    # 2.5 - CUPS printer support
    if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libcups"; then
        success "FreeRDP compiled with CUPS printer support"
    else
        warning "FreeRDP may be missing printer support"
    fi

    # 2.6 - OpenSSL/TLS support
    if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libssl"; then
        success "FreeRDP compiled with OpenSSL/TLS support"
    else
        error "FreeRDP MISSING OpenSSL support (RDP security will fail)"
    fi

    # 2.7 - X11 support
    if ldd /usr/local/bin/xfreerdp 2>/dev/null | grep -q "libX11"; then
        success "FreeRDP compiled with X11 support"
    else
        error "FreeRDP MISSING X11 support (cannot display)"
    fi

    # 2.8 - FreeRDP libraries exist
    log "Checking FreeRDP shared libraries..."
    local freerdp_libs_count=$(find /usr/local/lib -name "libfreerdp*.so*" 2>/dev/null | wc -l)
    if [ "$freerdp_libs_count" -gt 0 ]; then
        success "FreeRDP shared libraries found ($freerdp_libs_count files)"
    else
        error "FreeRDP shared libraries MISSING"
    fi

    # 2.9 - Test FreeRDP can show help
    if /usr/local/bin/xfreerdp /help 2>&1 | grep -q "FreeRDP"; then
        success "FreeRDP executable can run"
    else
        error "FreeRDP executable CANNOT run"
    fi
}

################################################################################
# CRITICAL CHECK 3: X.org Server Validation
################################################################################

verify_xorg_server() {
    section "CRITICAL CHECK 3: X.ORG SERVER VALIDATION"

    log "Checking X.org installation..."

    # 3.1 - X.org binary exists
    local xorg_bin=""
    if [ -f /usr/lib/xorg/Xorg ]; then
        xorg_bin="/usr/lib/xorg/Xorg"
    elif [ -f /usr/bin/Xorg ]; then
        xorg_bin="/usr/bin/Xorg"
    fi

    if [ -n "$xorg_bin" ]; then
        success "X.org binary found at $xorg_bin"
    else
        error "X.org binary NOT FOUND"
        return 1
    fi

    # 3.2 - X.org version check
    if $xorg_bin -version 2>&1 | grep -q "X.Org"; then
        local xorg_ver=$($xorg_bin -version 2>&1 | grep "X.Org X Server" | awk '{print $4}')
        success "X.org version: $xorg_ver"
    else
        error "X.org version check FAILED"
    fi

    # 3.3 - X.org video drivers
    log "Checking X.org video drivers..."
    local drivers_found=0
    local driver_dir="/usr/lib/xorg/modules/drivers"

    if [ ! -d "$driver_dir" ]; then
        error "X.org drivers directory NOT FOUND: $driver_dir"
        return 1
    fi

    for driver in modesetting_drv.so vesa_drv.so vmware_drv.so; do
        if [ -f "$driver_dir/$driver" ]; then
            success "X.org driver: $driver"
            ((drivers_found++))
        else
            warning "X.org driver MISSING: $driver"
        fi
    done

    if [ $drivers_found -eq 0 ]; then
        error "NO X.org video drivers found"
        return 1
    fi

    # 3.4 - X.org input drivers
    log "Checking X.org input drivers..."
    local input_dir="/usr/lib/xorg/modules/input"
    local input_drivers_found=0

    if [ ! -d "$input_dir" ]; then
        error "X.org input drivers directory NOT FOUND: $input_dir"
        return 1
    fi

    for driver in evdev_drv.so libinput_drv.so; do
        if [ -f "$input_dir/$driver" ]; then
            success "X.org input driver: $driver"
            ((input_drivers_found++))
        else
            warning "X.org input driver MISSING: $driver"
        fi
    done

    if [ $input_drivers_found -eq 0 ]; then
        error "NO X.org input drivers found (keyboard/mouse will NOT work)"
        return 1
    fi

    # 3.5 - X11 libraries
    log "Checking X11 libraries..."
    if [ -f /usr/lib/x86_64-linux-gnu/libX11.so.6 ]; then
        success "libX11.so.6 present"
    else
        error "libX11.so.6 MISSING"
    fi

    if [ -f /usr/lib/x86_64-linux-gnu/libXrandr.so.2 ]; then
        success "libXrandr.so.2 present (for resolution control)"
    else
        warning "libXrandr.so.2 MISSING (resolution changes may not work)"
    fi
}

################################################################################
# CRITICAL CHECK 4: TFTP Server Functional Test
################################################################################

verify_tftp_server() {
    section "CRITICAL CHECK 4: TFTP SERVER FUNCTIONAL TEST"

    log "Checking TFTP server..."

    # 4.1 - TFTP package installed
    if dpkg -l | grep -q "tftpd-hpa"; then
        success "tftpd-hpa package installed"
    else
        error "tftpd-hpa package NOT installed"
        return 1
    fi

    # 4.2 - TFTP configuration file
    if [ -f /etc/default/tftpd-hpa ]; then
        success "TFTP configuration file exists"
    else
        error "TFTP configuration file MISSING"
        return 1
    fi

    # 4.3 - TFTP directory configured
    local tftp_dir=$(grep "TFTP_DIRECTORY" /etc/default/tftpd-hpa 2>/dev/null | cut -d'"' -f2)
    if [ -n "$tftp_dir" ] && [ -d "$tftp_dir" ]; then
        success "TFTP directory configured: $tftp_dir"
    else
        error "TFTP directory NOT configured or does not exist"
        return 1
    fi

    # 4.4 - TFTP directory permissions
    if [ -r "$tftp_dir" ] && [ -x "$tftp_dir" ]; then
        success "TFTP directory has correct permissions"
    else
        error "TFTP directory permissions incorrect"
    fi

    # 4.5 - TFTP service running
    if systemctl is-active --quiet tftpd-hpa 2>/dev/null; then
        success "TFTP service is RUNNING"
    else
        error "TFTP service is NOT running"
        return 1
    fi

    # 4.6 - TFTP listening on port 69
    if ss -ulnp 2>/dev/null | grep -q ":69 " || netstat -ulnp 2>/dev/null | grep -q ":69 "; then
        success "TFTP server listening on UDP port 69"
    else
        error "TFTP server NOT listening on port 69"
        return 1
    fi

    # 4.7 - TFTP functional test (can serve files)
    log "Testing TFTP file transfer..."
    local test_file="$tftp_dir/tftp-test-$$-$(date +%s).txt"
    local test_content="Thin-Server TFTP TEST $(date)"

    echo "$test_content" > "$test_file" 2>/dev/null || {
        error "Cannot create test file in TFTP directory"
        return 1
    }

    chmod 644 "$test_file"
    local test_filename=$(basename "$test_file")

    # Try to fetch file via TFTP
    if command -v tftp >/dev/null 2>&1; then
        local temp_dest="/tmp/tftp-test-result-$$.txt"
        if echo "get $test_filename $temp_dest" | tftp 127.0.0.1 2>/dev/null; then
            if [ -f "$temp_dest" ] && grep -q "Thin-Server TFTP TEST" "$temp_dest" 2>/dev/null; then
                success "TFTP server can serve files (functional test PASSED)"
                rm -f "$temp_dest"
            else
                error "TFTP transfer failed (file content mismatch)"
            fi
        else
            error "TFTP transfer command FAILED"
        fi
    else
        warning "tftp client not installed, skipping functional test"
    fi

    # Cleanup test file
    rm -f "$test_file"

    # 4.8 - TFTP secure mode check
    if grep -q "\-\-secure" /etc/default/tftpd-hpa; then
        success "TFTP server running in secure mode"
    else
        warning "TFTP server may not be in secure mode"
    fi
}

################################################################################
# IMPORTANT CHECK 5: Initramfs /init Script Validation
################################################################################

verify_init_script() {
    section "IMPORTANT CHECK 5: INITRAMFS /INIT SCRIPT VALIDATION"

    local init_script="$EXTRACT_DIR/init"

    if [ ! -f "$init_script" ]; then
        error "Init script NOT FOUND in initramfs"
        return 1
    fi
    success "Init script exists"

    # 5.1 - Executable
    if [ -x "$init_script" ]; then
        success "Init script is executable"
    else
        error "Init script is NOT executable"
    fi

    # 5.2 - Shebang line
    if head -1 "$init_script" | grep -q "^#!"; then
        success "Init script has shebang line"
    else
        warning "Init script missing shebang line"
    fi

    # 5.3 - Required sections
    log "Checking init script sections..."

    local required_sections=(
        "NETWORK"
        "NTP"
        "X"
        "RDP"
    )

    for section_name in "${required_sections[@]}"; do
        if grep -qi "$section_name" "$init_script"; then
            success "Init script has $section_name section"
        else
            error "Init script MISSING $section_name section"
        fi
    done

    # 5.4 - RDP retry logic
    if grep -q "MAX_RDP_RETRIES" "$init_script"; then
        local max_retries=$(grep "MAX_RDP_RETRIES=" "$init_script" | head -1 | cut -d'=' -f2)
        success "RDP retry logic present (max retries: $max_retries)"
    else
        error "RDP retry logic MISSING"
    fi

    # 5.5 - Kernel parameter parsing
    log "Checking kernel parameter parsing..."
    local required_params=("rdserver" "rdpuser" "resolution" "sound" "printer")

    for param in "${required_params[@]}"; do
        if grep -q "${param}=" "$init_script"; then
            success "Init script parses parameter: $param"
        else
            error "Init script does NOT parse: $param"
        fi
    done

    # 5.6 - Heartbeat mechanism
    if grep -q "heartbeat" "$init_script" || grep -q "/api/heartbeat" "$init_script"; then
        success "Heartbeat mechanism present"
    else
        warning "Heartbeat mechanism may be missing"
    fi

    # 5.7 - Error handling
    if grep -q "set -e" "$init_script" || grep -q "trap" "$init_script"; then
        success "Init script has error handling"
    else
        warning "Init script may lack proper error handling"
    fi
}

################################################################################
# IMPORTANT CHECK 6: Kernel Modules Verification
################################################################################

verify_kernel_modules() {
    section "IMPORTANT CHECK 6: KERNEL MODULES IN INITRAMFS"

    local modules_dir="$EXTRACT_DIR/lib/modules"

    if [ ! -d "$modules_dir" ]; then
        error "Kernel modules directory NOT FOUND in initramfs"
        return 1
    fi
    success "Kernel modules directory exists"

    # 6.1 - Network drivers
    log "Checking network drivers..."
    local network_modules=("e1000.ko" "e1000e.ko" "r8169.ko" "vmxnet3.ko" "virtio_net.ko")
    local net_found=0

    for mod in "${network_modules[@]}"; do
        if find "$modules_dir" -name "$mod" 2>/dev/null | grep -q .; then
            success "Network module: $mod"
            ((net_found++))
        else
            warning "Network module MISSING: $mod"
        fi
    done

    if [ $net_found -eq 0 ]; then
        error "NO network modules found (network will NOT work)"
        return 1
    fi

    # 6.2 - DRM video modules
    log "Checking DRM/video modules..."
    local drm_modules=("drm.ko" "drm_kms_helper.ko")

    for mod in "${drm_modules[@]}"; do
        if find "$modules_dir" -name "$mod" 2>/dev/null | grep -q .; then
            success "DRM module: $mod"
        else
            error "DRM module MISSING: $mod"
        fi
    done

    # 6.3 - USB modules
    log "Checking USB modules..."
    local usb_modules=("usb-storage.ko" "usbhid.ko" "ehci-hcd.ko" "xhci-hcd.ko")
    local usb_found=0

    for mod in "${usb_modules[@]}"; do
        if find "$modules_dir" -name "$mod" 2>/dev/null | grep -q .; then
            success "USB module: $mod"
            ((usb_found++))
        else
            warning "USB module MISSING: $mod"
        fi
    done

    if [ $usb_found -lt 2 ]; then
        warning "Few USB modules found (USB may not work fully)"
    fi

    # 6.4 - Input modules
    log "Checking input modules..."
    if find "$modules_dir" -name "evdev.ko" 2>/dev/null | grep -q .; then
        success "Input module: evdev.ko"
    else
        error "Input module MISSING: evdev.ko (keyboard/mouse will NOT work)"
    fi

    # 6.5 - Sound modules (optional but recommended)
    log "Checking sound modules..."
    if find "$modules_dir" -name "snd*.ko" 2>/dev/null | grep -q .; then
        local snd_count=$(find "$modules_dir" -name "snd*.ko" 2>/dev/null | wc -l)
        success "Sound modules found ($snd_count modules)"
    else
        warning "Sound modules MISSING (sound may not work)"
    fi
}

################################################################################
# IMPORTANT CHECK 7: BusyBox Applets Verification
################################################################################

verify_busybox_applets() {
    section "IMPORTANT CHECK 7: BUSYBOX APPLETS CHECK"

    local busybox_bin="$EXTRACT_DIR/bin/busybox"

    if [ ! -f "$busybox_bin" ]; then
        error "BusyBox binary NOT FOUND in initramfs"
        return 1
    fi
    success "BusyBox binary exists"

    # 7.1 - Executable
    if [ -x "$busybox_bin" ]; then
        success "BusyBox binary is executable"
    else
        error "BusyBox binary is NOT executable"
        return 1
    fi

    # 7.2 - Required applets
    log "Checking BusyBox applets..."

    local required_applets=(
        "sh"
        "ip"
        "wget"
        "udhcpc"
        "modprobe"
        "mount"
        "umount"
        "tee"
        "grep"
        "cat"
        "echo"
        "sleep"
        "mkdir"
        "ln"
        "chmod"
    )

    local missing_applets=0

    for applet in "${required_applets[@]}"; do
        if "$busybox_bin" --list 2>/dev/null | grep -q "^${applet}$"; then
            success "BusyBox applet: $applet"
        else
            error "BusyBox MISSING applet: $applet"
            ((missing_applets++))
        fi
    done

    if [ $missing_applets -gt 0 ]; then
        error "BusyBox is missing $missing_applets critical applets"
        return 1
    fi

    # 7.3 - BusyBox symlinks
    log "Checking BusyBox symlinks..."
    local symlinks_count=$(find "$EXTRACT_DIR/bin" "$EXTRACT_DIR/sbin" -type l 2>/dev/null | wc -l)
    if [ $symlinks_count -gt 10 ]; then
        success "BusyBox symlinks created ($symlinks_count symlinks)"
    else
        warning "Few BusyBox symlinks found ($symlinks_count)"
    fi
}

################################################################################
# IMPORTANT CHECK 8: Flask API Endpoints Test
################################################################################

verify_flask_api() {
    section "IMPORTANT CHECK 8: FLASK API ENDPOINTS TEST"

    log "Checking Flask application..."

    # 8.1 - Flask service running
    if systemctl is-active --quiet thinclient-manager 2>/dev/null; then
        success "Flask service (thinclient-manager) is RUNNING"
    else
        error "Flask service is NOT running"
        return 1
    fi

    # 8.2 - Flask listening on port 5000
    if ss -tlnp 2>/dev/null | grep -q ":5000" || netstat -tlnp 2>/dev/null | grep -q ":5000"; then
        success "Flask listening on TCP port 5000"
    else
        error "Flask NOT listening on port 5000"
        return 1
    fi

    # 8.3 - Flask responding
    log "Testing Flask HTTP response..."
    local flask_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/ 2>/dev/null || echo "000")
    if [ "$flask_code" = "200" ] || [ "$flask_code" = "302" ]; then
        success "Flask responding (HTTP $flask_code)"
    else
        error "Flask NOT responding correctly (HTTP $flask_code)"
        return 1
    fi

    # 8.4 - Test critical API endpoints
    log "Testing critical API endpoints..."

    # Health/status endpoint
    if curl -s http://127.0.0.1:5000/api/system/health 2>/dev/null | grep -q "status"; then
        success "Health endpoint (/api/system/health) working"
    else
        warning "Health endpoint may not be working"
    fi

    # Stats endpoint
    if curl -s http://127.0.0.1:5000/api/stats/peripherals 2>/dev/null | grep -q "\["; then
        success "Stats endpoint (/api/stats/peripherals) returning JSON"
    else
        warning "Stats endpoint may not be working"
    fi

    # 8.5 - Test authentication endpoint
    log "Testing authentication..."
    local auth_response=$(curl -s -X POST http://127.0.0.1:5000/api/auth/login \
        -H "Content-Type: application/json" \
        -d '{"username":"nonexistent","password":"wrong"}' 2>/dev/null)

    if echo "$auth_response" | grep -q "error"; then
        success "Authentication endpoint responding correctly"
    else
        warning "Authentication endpoint may not be configured"
    fi

    # 8.6 - Test API returns JSON
    local api_test=$(curl -s http://127.0.0.1:5000/api/system/stats 2>/dev/null)
    if echo "$api_test" | python3 -m json.tool >/dev/null 2>&1; then
        success "API endpoints return valid JSON"
    else
        warning "API endpoints may not return valid JSON"
    fi
}

################################################################################
# IMPORTANT CHECK 9: Database Schema Validation
################################################################################

verify_database_schema() {
    section "IMPORTANT CHECK 9: DATABASE SCHEMA VALIDATION"

    local db_path="/opt/thinclient-manager/db/clients.db"

    if [ ! -f "$db_path" ]; then
        error "Database NOT FOUND at $db_path"
        return 1
    fi
    success "Database file exists"

    # 9.1 - Database integrity
    local integrity=$(sqlite3 "$db_path" "PRAGMA integrity_check;" 2>/dev/null)
    if [ "$integrity" = "ok" ]; then
        success "Database integrity check PASSED"
    else
        error "Database integrity check FAILED: $integrity"
        return 1
    fi

    # 9.2 - Client table schema
    log "Validating Client table schema..."
    local client_cols=$(sqlite3 "$db_path" "PRAGMA table_info(client);" 2>/dev/null | awk -F'|' '{print $2}')

    local required_client_cols=("id" "mac" "hostname" "rdp_server" "rdp_user" "rdp_password" "resolution")
    for col in "${required_client_cols[@]}"; do
        if echo "$client_cols" | grep -q "^${col}$"; then
            success "Client table has column: $col"
        else
            error "Client table MISSING column: $col"
        fi
    done

    # 9.3 - Admin table schema
    log "Validating Admin table schema..."
    local admin_cols=$(sqlite3 "$db_path" "PRAGMA table_info(admin);" 2>/dev/null | awk -F'|' '{print $2}')

    local required_admin_cols=("id" "username" "password")
    for col in "${required_admin_cols[@]}"; do
        if echo "$admin_cols" | grep -q "^${col}$"; then
            success "Admin table has column: $col"
        else
            error "Admin table MISSING column: $col"
        fi
    done

    # 9.4 - ClientLog table exists
    if sqlite3 "$db_path" ".tables" 2>/dev/null | grep -q "client_log"; then
        success "ClientLog table exists"
    else
        error "ClientLog table MISSING"
    fi

    # 9.5 - AuditLog table exists
    if sqlite3 "$db_path" ".tables" 2>/dev/null | grep -q "audit_log"; then
        success "AuditLog table exists"
    else
        error "AuditLog table MISSING"
    fi

    # 9.6 - BootToken table exists
    if sqlite3 "$db_path" ".tables" 2>/dev/null | grep -q "boot_token"; then
        success "BootToken table exists"
    else
        warning "BootToken table MISSING (boot tokens may not work)"
    fi

    # 9.7 - Admin user exists
    local admin_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM admin;" 2>/dev/null || echo "0")
    if [ "$admin_count" -gt 0 ]; then
        success "Admin users exist ($admin_count admin(s))"
    else
        error "NO admin users (cannot login to web panel)"
        log "  Fix: cd /opt/thinclient-manager && python3 cli.py admin create <username> <password>"
    fi

    # 9.8 - Check database size
    local db_size=$(du -h "$db_path" | cut -f1)
    success "Database size: $db_size"
}

################################################################################
# Main Execution
################################################################################

main() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "  THIN-SERVER THINCLIENT MANAGER - EXTENDED VALIDATION"
    echo "  Version: 1.0.0"
    echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Extract initramfs first (needed for checks 5, 6, 7)
    if ! extract_initramfs; then
        error "Failed to extract initramfs, some checks will be skipped"
    fi

    # Run CRITICAL checks (Priority 1)
    verify_nginx_config
    verify_freerdp_features
    verify_xorg_server
    verify_tftp_server

    # Run IMPORTANT checks (Priority 2) - only if initramfs extracted
    if [ -d "$EXTRACT_DIR" ]; then
        verify_init_script
        verify_kernel_modules
        verify_busybox_applets
    else
        warning "Skipping initramfs-based checks (extraction failed)"
    fi

    verify_flask_api
    verify_database_schema

    # Summary
    section "VALIDATION SUMMARY"

    echo ""
    echo "Total Checks:    $TOTAL_CHECKS"
    echo -e "${GREEN}Passed:${NC}          $PASSED_CHECKS"
    echo -e "${RED}Failed:${NC}          $FAILED_CHECKS"
    echo -e "${YELLOW}Warnings:${NC}        $WARNING_CHECKS"
    echo ""

    if [ $FAILED_CHECKS -eq 0 ]; then
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ✓ ALL EXTENDED VALIDATION CHECKS PASSED${NC}"
        echo -e "${GREEN}════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        exit 0
    else
        echo -e "${RED}════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  ✗ VALIDATION ISSUES FOUND: $FAILED_CHECKS${NC}"
        echo -e "${RED}════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        exit 1
    fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
