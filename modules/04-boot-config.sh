#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

MODULE_NAME="boot-config"
MODULE_VERSION="$APP_VERSION"

log "═══════════════════════════════════════"
log "Installing: Boot Config v$MODULE_VERSION"
log "═══════════════════════════════════════"

# ============================================
# SETUP iPXE
# ============================================
setup_ipxe() {
    log "Setting up iPXE configuration..."

    #Create directories with validation
    log "  Creating directory structure..."
    ensure_dir "$WEB_ROOT" 755
    ensure_dir "$WEB_ROOT/kernels" 755
    ensure_dir "$WEB_ROOT/initrds" 755
    ensure_dir "$TFTP_ROOT" 755
    ensure_dir "$TFTP_ROOT/efi64" 755

    # Verify directories are writable
    for dir in "$WEB_ROOT" "$TFTP_ROOT"; do
        if [ ! -w "$dir" ]; then
            error "Directory not writable: $dir"
            return 1
        fi
    done
    log "  ✓ Directories created and writable"

    #Copy kernel with detailed validation
    log "  Locating system kernel..."
    local kernel_path=$(find /boot -name "vmlinuz-*" -type f | sort -V | tail -1)

    #Better error message with fix instructions
    if [ -z "$kernel_path" ]; then
        error "╔════════════════════════════════════════════╗"
        error "║  ✗ NO KERNEL FOUND                         ║"
        error "╚════════════════════════════════════════════╝"
        error ""
        error "No kernel files found in /boot directory"
        error "Expected files like: /boot/vmlinuz-5.10.0-*"
        error ""
        error "Current kernel: $(uname -r)"
        error ""
        error "To fix this issue:"
        error "  1. Install kernel package:"
        error "     apt-get install linux-image-$(uname -r)"
        error ""
        error "  2. Or install generic kernel:"
        error "     apt-get install linux-image-amd64"
        error ""
        error "  3. After installing, run this module again:"
        error "     sudo ./install.sh update 04-boot-config"
        error ""
        return 1
    fi

    local kernel_version=$(basename "$kernel_path" | sed 's/vmlinuz-//')
    log "  Found kernel: $kernel_version"

    # Check kernel size (should be >5MB)
    local kernel_size=$(stat -c%s "$kernel_path" 2>/dev/null || stat -f%z "$kernel_path" 2>/dev/null || echo "0")
    if [ "$kernel_size" -lt 5000000 ]; then
        error "Kernel file too small: $kernel_size bytes (expected >5MB)"
        return 1
    fi
    log "  Kernel size: $(($kernel_size / 1024 / 1024)) MB"

    # Copy kernel
    if ! cp "$kernel_path" "$WEB_ROOT/kernels/vmlinuz"; then
        error "Failed to copy kernel to $WEB_ROOT/kernels/"
        return 1
    fi

    # Verify copy
    local copied_size=$(stat -c%s "$WEB_ROOT/kernels/vmlinuz" 2>/dev/null || stat -f%z "$WEB_ROOT/kernels/vmlinuz" 2>/dev/null || echo "0")
    if [ "$copied_size" != "$kernel_size" ]; then
        error "Kernel copy verification failed (size mismatch)"
        return 1
    fi

    log "  ✓ Kernel copied and verified: $kernel_version ($(($kernel_size / 1024 / 1024)) MB)"

    #Download iPXE EFI bootloader with validation
    log "  Downloading iPXE EFI bootloader..."

    local ipxe_url="http://boot.ipxe.org/ipxe.efi"
    local download_success=false

    # Try primary source
    log "    Source: $ipxe_url"
    if wget -q --timeout=30 --tries=3 -O "$TFTP_ROOT/efi64/bootx64.efi" "$ipxe_url" 2>&1 | tee -a "$LOG_FILE"; then
        download_success=true
        log "    ✓ Downloaded from primary source"
    else
        warn "    ✗ Primary source failed, trying alternative..."

        # Try alternative source
        ipxe_url="https://github.com/ipxe/ipxe/releases/download/v1.21.1/ipxe.efi"
        log "    Source: $ipxe_url"
        if wget -q --timeout=30 --tries=3 -O "$TFTP_ROOT/efi64/bootx64.efi" "$ipxe_url" 2>&1 | tee -a "$LOG_FILE"; then
            download_success=true
            log "    ✓ Downloaded from alternative source"
        else
            error "    ✗ All download sources failed"
        fi
    fi

    if [ "$download_success" = false ]; then
        error "Failed to download iPXE bootloader from any source"
        error "  Check internet connectivity or download manually:"
        error "  wget -O $TFTP_ROOT/efi64/bootx64.efi http://boot.ipxe.org/ipxe.efi"
        return 1
    fi

    # Validate downloaded file
    if [ ! -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
        error "iPXE bootloader file not created"
        return 1
    fi

    local ipxe_size=$(stat -c%s "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || stat -f%z "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || echo "0")

    # iPXE EFI should be ~1-2MB
    if [ "$ipxe_size" -lt 100000 ]; then
        error "iPXE bootloader too small: $ipxe_size bytes (expected >100KB)"
        error "  File may be corrupted or incomplete"
        return 1
    fi

    if [ "$ipxe_size" -gt 10000000 ]; then
        warn "iPXE bootloader unusually large: $(($ipxe_size / 1024 / 1024)) MB"
        warn "  Expected size: 1-2 MB"
    fi

    # Check if file is a valid PE executable (EFI binary)
    if ! file "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null | grep -q "PE32+"; then
        warn "iPXE file may not be a valid EFI executable"
        warn "  $(file "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null)"
    fi

    log "  ✓ iPXE EFI bootloader downloaded and validated"
    log "    Size: $(($ipxe_size / 1024)) KB"
    log "    Path: $TFTP_ROOT/efi64/bootx64.efi"

    log "  Creating autoexec.ipxe..."

    cat > "$TFTP_ROOT/autoexec.ipxe" << 'EOF'
#!ipxe

# Thin-Server ThinClient - Auto-boot script 
#Використовує DHCP next-server для віддалених клієнтів
# Це дозволяє працювати як локальним VM, так і фізичним ПК в мережі

dhcp || goto retry

# Спробувати отримати server IP з DHCP
isset ${next-server} && set boot-server ${next-server} || goto try_proxydhcp
goto chain_boot

:try_proxydhcp
# Якщо next-server не встановлено, спробувати proxydhcp
isset ${proxydhcp/next-server} && set boot-server ${proxydhcp/next-server} || goto use_fallback
goto chain_boot

:use_fallback
# Останній fallback - використати сконфігурований IP
set boot-server @@SERVER_IP@@

:chain_boot
echo Booting from server: ${boot-server}
chain http://${boot-server}/boot.ipxe || goto failed

:failed
echo Boot failed, retrying in 5 seconds...
sleep 5
goto retry

:retry
echo DHCP retry...
sleep 3
dhcp
isset ${next-server} && set boot-server ${next-server} || set boot-server @@SERVER_IP@@
chain http://${boot-server}/boot.ipxe || shell
EOF

    #Replace SERVER_IP placeholder AFTER creating file
    sed -i.bak "s/@@SERVER_IP@@/$SERVER_IP/g" "$TFTP_ROOT/autoexec.ipxe"
    rm -f "$TFTP_ROOT/autoexec.ipxe.bak"

    # Validate autoexec.ipxe
    if [ ! -f "$TFTP_ROOT/autoexec.ipxe" ]; then
        error "autoexec.ipxe was not created"
        return 1
    fi

    local autoexec_size=$(stat -c%s "$TFTP_ROOT/autoexec.ipxe" 2>/dev/null || stat -f%z "$TFTP_ROOT/autoexec.ipxe" 2>/dev/null || echo "0")
    if [ "$autoexec_size" -lt 100 ]; then
        error "autoexec.ipxe too small: $autoexec_size bytes"
        return 1
    fi

    # Verify SERVER_IP was replaced
    if grep -q "@@SERVER_IP@@" "$TFTP_ROOT/autoexec.ipxe"; then
        error "SERVER_IP placeholder not replaced in autoexec.ipxe"
        error "  File contains: @@SERVER_IP@@"
        return 1
    fi

    # Verify it contains the boot server line
    if ! grep -q "set boot-server" "$TFTP_ROOT/autoexec.ipxe"; then
        error "autoexec.ipxe missing boot-server configuration"
        return 1
    fi

    log "  ✓ autoexec.ipxe created and validated"
    log "    Size: $autoexec_size bytes"
    log "    Boot server: $SERVER_IP (fallback)"

    # Set permissions
    chmod 644 "$TFTP_ROOT/efi64/bootx64.efi"
    chmod 644 "$TFTP_ROOT/autoexec.ipxe"

    # Set ownership for TFTP
    log "  Setting TFTP ownership..."
    if chown -R tftp:tftp "$TFTP_ROOT" 2>/dev/null; then
        log "  ✓ Owner: tftp:tftp"
    elif chown -R nobody:nogroup "$TFTP_ROOT" 2>/dev/null; then
        log "  ✓ Owner: nobody:nogroup"
    else
        warn "  Could not set TFTP directory ownership"
    fi

    # Verify TFTP files are readable
    if [ ! -r "$TFTP_ROOT/efi64/bootx64.efi" ] || [ ! -r "$TFTP_ROOT/autoexec.ipxe" ]; then
        error "TFTP files not readable"
        error "  Check permissions on: $TFTP_ROOT"
        return 1
    fi

    log "✓ iPXE setup completed successfully"
    log "  TFTP Root: $TFTP_ROOT"
    log "  Files: bootx64.efi ($(($ipxe_size / 1024)) KB), autoexec.ipxe ($autoexec_size bytes)"
    return 0
}

# ============================================
# SETUP TFTP
# ============================================
setup_tftp() {
    log "Setting up TFTP server..."

    #Check if tftp user exists
    log "  Checking TFTP user..."
    if ! id tftp >/dev/null 2>&1; then
        warn "  tftp user does not exist, will use nobody"
    else
        log "  ✓ tftp user exists"
    fi

    # Install TFTP if not present
    if ! command -v in.tftpd >/dev/null 2>&1; then
        log "  Installing tftpd-hpa package..."
        if ! apt-get install -y tftpd-hpa 2>&1 | tee -a "$LOG_FILE"; then
            error "Failed to install TFTP server"
            error "  Try manually: apt-get install tftpd-hpa"
            return 1
        fi
        log "  ✓ tftpd-hpa installed"
    else
        log "  ✓ tftpd-hpa already installed"
    fi

    #Backup existing configuration
    if [ -f "/etc/default/tftpd-hpa" ]; then
        log "  Backing up existing TFTP configuration..."
        backup_file /etc/default/tftpd-hpa
    fi

    #Create TFTP configuration
    log "  Creating TFTP configuration..."
    cat > /etc/default/tftpd-hpa << EOF
# Thin-Server TFTP Configuration 
# Generated: $(date)
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$TFTP_ROOT"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --verbose"
EOF

    # Verify configuration was created
    if [ ! -f "/etc/default/tftpd-hpa" ]; then
        error "TFTP configuration file not created"
        return 1
    fi

    # Verify TFTP_DIRECTORY is set correctly
    local configured_dir=$(grep "^TFTP_DIRECTORY=" /etc/default/tftpd-hpa | cut -d'=' -f2 | tr -d '"')
    if [ "$configured_dir" != "$TFTP_ROOT" ]; then
        error "TFTP directory not configured correctly"
        error "  Expected: $TFTP_ROOT"
        error "  Got: $configured_dir"
        return 1
    fi
    log "  ✓ TFTP configuration created"
    log "    Directory: $TFTP_ROOT"
    log "    Address: 0.0.0.0:69"

    #Set proper permissions
    log "  Setting TFTP directory permissions..."
    chmod -R 755 "$TFTP_ROOT"

    # Set ownership
    if chown -R tftp:tftp "$TFTP_ROOT" 2>/dev/null; then
        log "  ✓ Owner: tftp:tftp"
    elif chown -R nobody:nogroup "$TFTP_ROOT" 2>/dev/null; then
        log "  ✓ Owner: nobody:nogroup"
    else
        warn "  Could not set ownership"
    fi

    #Enable and restart TFTP service
    log "  Enabling TFTP service..."
    if ! systemctl enable tftpd-hpa 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to enable TFTP service"
        return 1
    fi

    log "  Restarting TFTP service..."
    if ! systemctl restart tftpd-hpa 2>&1 | tee -a "$LOG_FILE"; then
        error "Failed to start TFTP service"
        error "  Checking service status..."
        systemctl status tftpd-hpa --no-pager || true
        journalctl -u tftpd-hpa -n 20 --no-pager || true
        return 1
    fi

    #Wait for service to stabilize
    log "  Waiting for TFTP service to start..."
    sleep 3

    # Verify service is active
    if ! systemctl is-active --quiet tftpd-hpa; then
        error "TFTP service failed to start"
        error "  Service status:"
        systemctl status tftpd-hpa --no-pager || true
        error "  Recent logs:"
        journalctl -u tftpd-hpa -n 20 --no-pager || true
        return 1
    fi
    log "  ✓ TFTP service is active"

    #Verify TFTP port is listening
    log "  Verifying TFTP port..."
    if netstat -uln 2>/dev/null | grep -q ":69 " || ss -uln 2>/dev/null | grep -q ":69 "; then
        log "  ✓ TFTP listening on UDP port 69"
    else
        error "TFTP port 69 not listening"
        error "  Check if another service is using port 69"
        netstat -uln 2>/dev/null | grep ":69" || ss -uln 2>/dev/null | grep ":69" || true
        return 1
    fi

    #Test TFTP accessibility (if tftp client available)
    if command -v tftp >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        log "  Testing TFTP file retrieval..."

        # Create a small test file
        echo "Thin-Server TFTP Test $(date)" > "$TFTP_ROOT/test.txt"

        # Try to retrieve it
        local tftp_test_ok=false
        if command -v tftp >/dev/null 2>&1; then
            if echo -e "get test.txt /tmp/tftp-test-$$\nquit" | tftp 127.0.0.1 >/dev/null 2>&1; then
                if [ -f "/tmp/tftp-test-$$" ]; then
                    tftp_test_ok=true
                    rm -f "/tmp/tftp-test-$$"
                fi
            fi
        fi

        # Cleanup test file
        rm -f "$TFTP_ROOT/test.txt"

        if [ "$tftp_test_ok" = true ]; then
            log "  ✓ TFTP file retrieval test PASSED"
        else
            warn "  TFTP file retrieval test skipped (tftp client not available)"
        fi
    fi

    log "✓ TFTP server configured and running"
    log "  Service: tftpd-hpa (enabled)"
    log "  Root: $TFTP_ROOT"
    log "  Port: UDP 69 (0.0.0.0)"
    log "  Files available: bootx64.efi, autoexec.ipxe"
    return 0
}

# ============================================
# CREATE BOOT FILES
# ============================================
create_boot_files() {
    log "Creating boot configuration files..."

    #Create boot.ipxe for HTTP delivery
    log "  Creating boot.ipxe..."

    cat > "$WEB_ROOT/boot.ipxe" << 'IPXE_SCRIPT'
#!ipxe
# Thin-Server ThinClient Boot Script 

echo ========================================
echo  Thin-Server ThinClient Boot System
echo ========================================
echo

:retry

# Get client MAC address
set mac ${net0/mac}
echo Client MAC: ${mac}

# Set server IP from DHCP or use default
isset ${next-server} && set server-ip ${next-server} || set server-ip @@SERVER_IP@@
echo Server: ${server-ip}

echo
echo Fetching client configuration...

# Get client-specific config from API
chain http://${server-ip}/api/boot/${mac} || goto failed

:failed
echo
echo ========================================
echo  Boot Failed - Retrying in 10 seconds
echo ========================================
echo
sleep 10
goto retry
IPXE_SCRIPT

    #Replace SERVER_IP placeholder
    sed -i.bak "s/@@SERVER_IP@@/$SERVER_IP/g" "$WEB_ROOT/boot.ipxe"
    rm -f "$WEB_ROOT/boot.ipxe.bak"

    #Verify boot.ipxe was created
    if [ ! -f "$WEB_ROOT/boot.ipxe" ]; then
        error "boot.ipxe was not created"
        return 1
    fi

    # Check file size
    local size=$(stat -c%s "$WEB_ROOT/boot.ipxe" 2>/dev/null || stat -f%z "$WEB_ROOT/boot.ipxe" 2>/dev/null || echo "0")
    if [ "$size" -lt 100 ]; then
        error "boot.ipxe is too small ($size bytes)"
        error "  File contents:"
        cat "$WEB_ROOT/boot.ipxe" | head -10 || true
        return 1
    fi
    log "    Size: $size bytes"

    #Verify iPXE shebang
    if ! head -1 "$WEB_ROOT/boot.ipxe" | grep -q "#!ipxe"; then
        error "boot.ipxe missing iPXE shebang"
        error "  First line: $(head -1 "$WEB_ROOT/boot.ipxe")"
        return 1
    fi
    log "    ✓ iPXE shebang present"

    #Verify SERVER_IP was replaced
    if grep -q "@@SERVER_IP@@" "$WEB_ROOT/boot.ipxe"; then
        error "SERVER_IP placeholder not replaced in boot.ipxe"
        return 1
    fi
    log "    ✓ SERVER_IP placeholder replaced: $SERVER_IP"

    #Verify it contains MAC address placeholder
    if ! grep -q '${mac}' "$WEB_ROOT/boot.ipxe"; then
        error "boot.ipxe missing MAC address placeholder"
        return 1
    fi
    log "    ✓ MAC address variable present"

    #Verify it contains API boot endpoint
    if ! grep -q "/api/boot/" "$WEB_ROOT/boot.ipxe"; then
        error "boot.ipxe missing API boot endpoint"
        return 1
    fi
    log "    ✓ API boot endpoint present"

    # Set permissions
    chmod 644 "$WEB_ROOT/boot.ipxe"
    log "  ✓ boot.ipxe created and validated"

    #Set proper ownership for web server
    log "  Setting web root ownership..."
    if chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null; then
        log "  ✓ Owner: www-data:www-data"
    else
        warn "  Could not set web root ownership"
    fi

    #Verify web server can read the file
    if [ ! -r "$WEB_ROOT/boot.ipxe" ]; then
        error "boot.ipxe not readable"
        return 1
    fi

    log "✓ Boot files created successfully"
    log "  boot.ipxe: $size bytes"
    log "  API endpoint: /api/boot/{MAC}"
    log "  Variables: server-ip, mac"
    return 0
}

# ============================================
# CREATE DRIVER PACKAGES
# ============================================
create_driver_packages() {
    log "Creating driver packages directory..."

    ensure_dir "$WEB_ROOT/drivers" 755
    touch "$WEB_ROOT/drivers/.placeholder"

    log "✓ Driver directory ready"
}

# ============================================
# DISPLAY DHCP CONFIGURATION EXAMPLES
# ============================================
display_dhcp_configuration() {
    log ""
    log "═══════════════════════════════════════════════════════════"
    log " IMPORTANT: DHCP Server Configuration Required"
    log "═══════════════════════════════════════════════════════════"
    log ""
    log "For remote PXE boot to work, your DHCP server MUST provide:"
    log "  1. next-server = $SERVER_IP"
    log "  2. filename = efi64/bootx64.efi"
    log ""
    log "Choose your DHCP server type and configure accordingly:"
    log ""
    log "─────────────────────────────────────────────────────────────"
    log "1. ISC DHCP Server (dhcpd)"
    log "─────────────────────────────────────────────────────────────"
    log "Edit /etc/dhcp/dhcpd.conf and add:"
    log ""
    log "  subnet 192.168.1.0 netmask 255.255.255.0 {"
    log "    range 192.168.1.100 192.168.1.200;"
    log "    option routers 192.168.1.1;"
    log "    option domain-name-servers 8.8.8.8;"
    log ""
    log "    # Thin-Server ThinClient PXE Boot"
    log "    next-server $SERVER_IP;"
    log "    filename \"efi64/bootx64.efi\";"
    log "  }"
    log ""
    log "Then restart: sudo systemctl restart isc-dhcp-server"
    log ""
    log "─────────────────────────────────────────────────────────────"
    log "2. dnsmasq (Lightweight DHCP)"
    log "─────────────────────────────────────────────────────────────"
    log "Edit /etc/dnsmasq.conf and add:"
    log ""
    log "  # DHCP range"
    log "  dhcp-range=192.168.1.100,192.168.1.200,12h"
    log ""
    log "  # Thin-Server ThinClient PXE Boot"
    log "  dhcp-boot=efi64/bootx64.efi,$SERVER_IP"
    log ""
    log "Then restart: sudo systemctl restart dnsmasq"
    log ""
    log "─────────────────────────────────────────────────────────────"
    log "3. Windows DHCP Server"
    log "─────────────────────────────────────────────────────────────"
    log "1. Open DHCP Manager"
    log "2. Right-click on your scope → Properties → Advanced"
    log "3. Set:"
    log "   - Boot file name: efi64/bootx64.efi"
    log "   - Next server (TFTP): $SERVER_IP"
    log "4. Click OK and restart DHCP service"
    log ""
    log "─────────────────────────────────────────────────────────────"
    log "4. MikroTik RouterOS"
    log "─────────────────────────────────────────────────────────────"
    log "/ip dhcp-server network set [find] \\"
    log "  next-server=$SERVER_IP \\"
    log "  boot-file-name=efi64/bootx64.efi"
    log ""
    log "─────────────────────────────────────────────────────────────"
    log "5. pfSense / OPNsense"
    log "─────────────────────────────────────────────────────────────"
    log "Services → DHCP Server → [Your Interface]"
    log ""
    log "Under \"Network Booting\":"
    log "  - Enable network booting: ✓"
    log "  - Next Server: $SERVER_IP"
    log "  - Default BIOS file name: efi64/bootx64.efi"
    log ""
    log "═══════════════════════════════════════════════════════════"
    log " Testing PXE Boot"
    log "═══════════════════════════════════════════════════════════"
    log ""
    log "From a different machine on the network, verify:"
    log ""
    log "1. TFTP is accessible:"
    log "   tftp $SERVER_IP"
    log "   tftp> get efi64/bootx64.efi"
    log "   tftp> quit"
    log ""
    log "2. HTTP boot file is accessible:"
    log "   curl http://$SERVER_IP/boot.ipxe"
    log ""
    log "3. Boot a test client via PXE and check logs:"
    log "   tail -f /var/log/nginx/thinclient/boot-requests.log"
    log "   journalctl -u tftpd-hpa -f"
    log ""
    log "═══════════════════════════════════════════════════════════"
    log ""
}

# ============================================
# VERIFY INSTALLATION
# ============================================
verify_installation() {
    log ""
    log "Verifying boot configuration..."
    
    local ok=true
    
    # Check TFTP service
    if systemctl is-active --quiet tftpd-hpa; then
        log "  ✓ TFTP service running"
    else
        error "  ✗ TFTP service NOT running"
        ok=false
    fi
    
    # Check TFTP directory setting
    local tftp_dir=$(grep "TFTP_DIRECTORY" /etc/default/tftpd-hpa | cut -d'"' -f2)
    if [ "$tftp_dir" = "$TFTP_ROOT" ]; then
        log "  ✓ TFTP directory: $tftp_dir"
    else
        error "  ✗ TFTP directory misconfigured: $tftp_dir (expected: $TFTP_ROOT)"
        ok=false
    fi
    
    #Check autoexec.ipxe in TFTP_ROOT
    if [ -f "$TFTP_ROOT/autoexec.ipxe" ]; then
        local size=$(stat -f%z "$TFTP_ROOT/autoexec.ipxe" 2>/dev/null || stat -c%s "$TFTP_ROOT/autoexec.ipxe" 2>/dev/null || echo "0")
        if [ "$size" -gt 50 ]; then
            log "  ✓ autoexec.ipxe exists ($size bytes)"
        else
            error "  ✗ autoexec.ipxe too small ($size bytes)"
            ok=false
        fi
    else
        error "  ✗ autoexec.ipxe NOT FOUND in $TFTP_ROOT"
        ok=false
    fi
    
    # Check iPXE bootloader in TFTP_ROOT
    if [ -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
        log "  ✓ iPXE bootloader exists in TFTP_ROOT"
    else
        error "  ✗ iPXE bootloader NOT FOUND in $TFTP_ROOT"
        ok=false
    fi
    
    # Check boot.ipxe in WEB_ROOT
    if [ -f "$WEB_ROOT/boot.ipxe" ]; then
        local size=$(stat -f%z "$WEB_ROOT/boot.ipxe" 2>/dev/null || stat -c%s "$WEB_ROOT/boot.ipxe" 2>/dev/null || echo "0")
        if [ "$size" -gt 100 ]; then
            log "  ✓ boot.ipxe exists in WEB_ROOT ($size bytes)"
        else
            error "  ✗ boot.ipxe too small ($size bytes)"
            ok=false
        fi
    else
        error "  ✗ boot.ipxe NOT FOUND in $WEB_ROOT"
        ok=false
    fi
    
    # Check kernel
    if [ -f "$WEB_ROOT/kernels/vmlinuz" ]; then
        log "  ✓ kernel exists"
    else
        error "  ✗ kernel NOT FOUND"
        ok=false
    fi
    
    # Check initramfs
    if [ -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
        log "  ✓ initramfs exists"
    else
        error "  ✗ initramfs NOT FOUND"
        ok=false
    fi
    
    #Test HTTP accessibility (localhost)
    if command -v curl >/dev/null 2>&1; then
        log "  Testing HTTP accessibility (localhost)..."
        sleep 2

        local http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/boot.ipxe" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            log "  ✓ boot.ipxe accessible via HTTP (200 OK)"

            # Verify content
            local content=$(curl -s "http://127.0.0.1/boot.ipxe" 2>/dev/null || echo "")
            if [ -z "$content" ]; then
                error "  ✗ boot.ipxe returns empty content"
                ok=false
            elif ! echo "$content" | grep -q "#!ipxe"; then
                error "  ✗ boot.ipxe has invalid content"
                log "    First 5 lines:"
                echo "$content" | head -5 | sed 's/^/      /'
                ok=false
            else
                log "  ✓ boot.ipxe content valid"
            fi
        else
            error "  ✗ boot.ipxe HTTP test failed (code: $http_code)"
            ok=false
        fi

        #Test HTTP accessibility via SERVER_IP (network test)
        if [ "$SERVER_IP" != "127.0.0.1" ] && [ "$SERVER_IP" != "localhost" ]; then
            log "  Testing HTTP accessibility via network IP..."

            local http_code_net=$(curl -s -o /dev/null -w "%{http_code}" "http://$SERVER_IP/boot.ipxe" 2>/dev/null || echo "000")

            if [ "$http_code_net" = "200" ]; then
                log "  ✓ boot.ipxe accessible via $SERVER_IP (NETWORK OK)"
                log "    Remote clients will be able to boot!"
            else
                error "  ✗ boot.ipxe NOT accessible via $SERVER_IP (code: $http_code_net)"
                error "    Remote clients will FAIL to boot!"
                error "    Check firewall/network configuration"
                ok=false
            fi
        fi
    fi

    #Test TFTP port accessibility
    log "  Checking TFTP port (UDP 69)..."
    if netstat -uln 2>/dev/null | grep -q ":69 " || ss -uln 2>/dev/null | grep -q ":69 "; then
        log "  ✓ TFTP listening on UDP port 69"
    else
        error "  ✗ TFTP NOT listening on port 69"
        ok=false
    fi

    #Warn about firewall if SERVER_IP is not localhost
    if [ "$SERVER_IP" != "127.0.0.1" ] && [ "$SERVER_IP" != "localhost" ]; then
        log ""
        log "  ⚠️  IMPORTANT for remote clients:"
        log "    1. Ensure firewall allows:"
        log "       - UDP port 69 (TFTP)"
        log "       - TCP port 80 (HTTP)"
        log "    2. Test from another machine:"
        log "       curl http://$SERVER_IP/boot.ipxe"
        log "    3. DHCP server must provide:"
        log "       - next-server = $SERVER_IP"
        log "       - filename = efi64/bootx64.efi"
    fi
    
    if [ "$ok" = false ]; then
        error "✗ Boot configuration verification FAILED"
        return 1
    fi
    
    log "✓ Boot configuration verification passed"
    return 0
}

# ============================================
# VALIDATE SERVER_IP
# ============================================
validate_server_ip() {
    log "Validating SERVER_IP configuration..."

    # Check if SERVER_IP is localhost
    if [[ "$SERVER_IP" == "127.0.0.1" ]] || [[ "$SERVER_IP" == "localhost" ]] || [[ "$SERVER_IP" == "::1" ]]; then
        error ""
        error "╔═══════════════════════════════════════════════════╗"
        error "║  ✗ INVALID SERVER_IP CONFIGURATION                ║"
        error "╚═══════════════════════════════════════════════════╝"
        error ""
        error "SERVER_IP is set to localhost ($SERVER_IP)!"
        error ""
        error "This will cause REMOTE CLIENTS to FAIL boot:"
        error "  - Virtual machines on this server: ✓ Will work"
        error "  - Physical PCs in network:         ✗ WILL NOT WORK"
        error ""
        error "Remote clients will try to boot from THEMSELVES (127.0.0.1)"
        error "instead of from this server!"
        error ""
        error "SOLUTION:"
        error "  1. Find your server's network IP:"
        error "     ip addr show | grep 'inet '"
        error ""
        error "  2. Edit config.env and set:"
        error "     SERVER_IP=<your-network-ip>  # e.g. 192.168.1.100"
        error ""
        error "  3. Re-run deployment:"
        error "     sudo bash deploy.sh"
        error ""
        return 1
    fi

    # Check if SERVER_IP looks like a valid IP
    if ! echo "$SERVER_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        warn "SERVER_IP doesn't look like an IPv4 address: $SERVER_IP"
        warn "Make sure it's reachable from network clients!"
    fi

    # Show what will be used
    log "✓ SERVER_IP: $SERVER_IP"
    log "  Remote clients will boot from: http://$SERVER_IP/boot.ipxe"

    return 0
}

# ============================================
# MAIN
# ============================================
main() {
    # Check dependencies
    if ! check_module_installed "initramfs"; then
        error "Dependency not met: initramfs"
        exit 1
    fi

    if ! check_module_installed "web-panel"; then
        error "Dependency not met: web-panel"
        exit 1
    fi

    #Validate SERVER_IP before proceeding
    if ! validate_server_ip; then
        exit 1
    fi
    
    # Install
    setup_ipxe || exit 1
    setup_tftp || exit 1
    create_boot_files || exit 1
    create_driver_packages
    
    # Verify
    if verify_installation; then
        log ""
        log "╔═══════════════════════════════════════════════════╗"
        log "║  ✓ BOOT CONFIG INSTALLED v$MODULE_VERSION        ║"
        log "╚═══════════════════════════════════════════════════╝"
        log ""
        log "📡 TFTP Server:"
        log "   Running on port 69"
        log "   Root: $TFTP_ROOT"
        log "   Files: efi64/bootx64.efi, autoexec.ipxe"
        log ""
        log "🌐 HTTP Boot Files:"
        log "   URL: http://$SERVER_IP/boot.ipxe"
        log "   Root: $WEB_ROOT"
        log ""
        log "🔧 API Endpoint:"
        log "   http://$SERVER_IP/api/boot/{MAC}"
        log ""
        log "✅ Quick Tests:"
        log "   curl http://$SERVER_IP/boot.ipxe"
        log "   tail -f /var/log/nginx/thinclient/boot-requests.log"
        log ""

        #Display DHCP configuration instructions
        display_dhcp_configuration

        exit 0
    else
        error "✗ Boot configuration failed verification"
        exit 1
    fi
}

main "$@"