#!/usr/bin/env bash
# Thin-Server ThinClient Manager - Main Installer
# Orchestrates all installation modules

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Installation modules in order
MODULES=(
    "01-core-system"
    "02-initramfs"
    "03-web-panel"
    "04-boot-config"
    "05-maintenance"
)

# ============================================
# USAGE / HELP
# ============================================
usage() {
    cat << EOF
╔═══════════════════════════════════════════════════╗
║   Thin-Server ThinClient Manager - Installer          ║
╚═══════════════════════════════════════════════════╝

Usage: $0 [command] [options]

COMMANDS:
  install                     Full system installation (all modules)
  install --skip-verification Fast installation (skip post-install checks)
  update <module>             Update specific module
  update all                  Update all modules
  status                      Check system status
  help                        Show this help message

OPTIONS:
  --skip-verification   Skip post-install verification (faster but not recommended)

MODULES:
  01-core-system       Base packages + FreeRDP compilation (~15 min)
  02-initramfs         Build initramfs image (~3 min)
  03-web-panel         Flask web app + Nginx (~30 sec)
  04-boot-config       iPXE + TFTP + boot scripts (~1 min)
  05-maintenance       Maintenance and backup tools

EXAMPLES:
  $0 install                  # Full installation
  $0 update 03-web-panel      # Update web panel only
  $0 update all               # Update all modules
  $0 status                   # Check system status

CONFIGURATION:
  Edit config.env before first installation:
    SERVER_IP          Server IP address
    RDS_SERVER         RDP server hostname
    NTP_SERVER         Time server
    FREERDP_VERSION    FreeRDP version to compile

LOGS:
  Installation:  $LOG_FILE
  Application:   /var/log/thinclient/app.log
  Nginx:         /var/log/nginx/thinclient/

DOCUMENTATION:
  README.md              Complete documentation
  docs/API.md            API reference
  docs/DEPLOYMENT.md     Deployment guide

SUPPORT:
  Run diagnostics:   ./modules/05-maintenance.sh diagnostics
  Create backup:     ./modules/05-maintenance.sh backup
  View logs:         tail -f /var/log/thinclient/app.log

EOF
}

# ============================================
# VERIFY MODULE FILES - FIXED
# ============================================
verify_module_files() {
    local module_name="$1"
    local all_ok=true
    
    case "$module_name" in
        "01-core-system")
            # Check FreeRDP
            if [ ! -f "/usr/local/bin/xfreerdp" ]; then
                error "  ✗ FreeRDP not installed"
                all_ok=false
            else
                log "  ✓ FreeRDP installed"
            fi
            ;;
            
        "02-initramfs")
            # Kernel is copied in 04-boot-config, not here
            if [ ! -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
                error "  ✗ Initramfs file not created"
                all_ok=false
            else
                local size=$(stat -f%z "$WEB_ROOT/initrds/initrd-minimal.img" 2>/dev/null || stat -c%s "$WEB_ROOT/initrds/initrd-minimal.img" 2>/dev/null || echo "0")
                if [ "$size" -lt 10000000 ]; then
                    error "  ✗ Initramfs too small: $size bytes"
                    all_ok=false
                else
                    log "  ✓ Initramfs created ($(du -h $WEB_ROOT/initrds/initrd-minimal.img | cut -f1))"
                fi
            fi
            ;;
            
        "03-web-panel")
            # Check Flask app files
            local required_files=("app.py" "config.py" "models.py" "utils.py")
            for file in "${required_files[@]}"; do
                if [ ! -f "$APP_DIR/$file" ]; then
                    error "  ✗ Missing: $file"
                    all_ok=false
                fi
            done
            
            # Check database
            if [ ! -f "$DB_DIR/clients.db" ]; then
                error "  ✗ Database not created"
                all_ok=false
            else
                if ! sqlite3 "$DB_DIR/clients.db" ".tables" 2>/dev/null | grep -q "client"; then
                    error "  ✗ Database has no tables"
                    all_ok=false
                else
                    log "  ✓ Database initialized"
                fi
            fi
            
            # Check service
            if ! systemctl is-active --quiet thinclient-manager 2>/dev/null; then
                error "  ✗ Flask service not running"
                all_ok=false
            else
                log "  ✓ Flask service running"
            fi
            
            # Check Nginx
            if ! systemctl is-active --quiet nginx 2>/dev/null; then
                error "  ✗ Nginx not running"
                all_ok=false
            else
                log "  ✓ Nginx running"
            fi
            ;;
            
        "04-boot-config")
            if [ ! -f "$WEB_ROOT/kernels/vmlinuz" ]; then
                error "  ✗ Kernel not copied"
                all_ok=false
            else
                log "  ✓ Kernel copied"
            fi

            #Don't re-check initramfs here (it's checked in 02-initramfs)
            # Just verify dependency was satisfied
            if [ ! -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
                error "  ✗ Initramfs dependency not satisfied"
                error "     Module 02-initramfs must complete successfully first"
                all_ok=false
            else
                log "  ✓ Initramfs dependency satisfied (from module 02)"
            fi
            
            # Check boot files
            if [ ! -f "$WEB_ROOT/boot.ipxe" ]; then
                error "  ✗ boot.ipxe not created"
                all_ok=false
            else
                log "  ✓ boot.ipxe created"
            fi
            
            # Check TFTP
            if [ ! -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
                error "  ✗ iPXE bootloader not found"
                all_ok=false
            else
                log "  ✓ iPXE bootloader exists"
            fi
            
            if [ ! -f "$TFTP_ROOT/autoexec.ipxe" ]; then
                error "  ✗ autoexec.ipxe not found"
                all_ok=false
            else
                log "  ✓ autoexec.ipxe exists"
            fi
            
            # Check TFTP service
            if ! systemctl is-active --quiet tftpd-hpa 2>/dev/null; then
                error "  ✗ TFTP service not running"
                all_ok=false
            else
                log "  ✓ TFTP service running"
            fi
            ;;
            
        "05-maintenance")
            # Check maintenance scripts
            if [ ! -x "$SCRIPT_DIR/modules/05-maintenance.sh" ]; then
                error "  ✗ Maintenance script not found or not executable"
                all_ok=false
            else
                log "  ✓ Maintenance script installed"
            fi

            # Check backup directory
            if [ ! -d "/opt/thin-server/backups" ]; then
                warn "  ⚠ Backup directory not created (will be created on first backup)"
            else
                log "  ✓ Backup directory exists"
            fi

            # Check cron jobs (optional)
            if [ -f "/etc/cron.d/thin-server-db-backup" ]; then
                log "  ✓ Database backup cron job configured"
            else
                warn "  ⚠ Database backup cron not set up (optional)"
            fi

            if [ -f "/etc/cron.daily/thin-server-db-cleanup" ]; then
                log "  ✓ Database cleanup cron job configured"
            else
                warn "  ⚠ Database cleanup cron not set up (optional)"
            fi
            ;;
    esac
    
    [ "$all_ok" = true ]
}

# ============================================
# INTER-MODULE VALIDATION
# ============================================
# Additional validation between modules to ensure dependencies
validate_inter_module_dependencies() {
    local completed_module="$1"

    log "  Checking inter-module dependencies for $completed_module..."

    case "$completed_module" in
        "01-core-system")
            # FreeRDP MUST be installed and working
            if ! /usr/local/bin/xfreerdp --version >/dev/null 2>&1; then
                error "  ✗ FreeRDP not working after 01-core-system"
                error "    Try: /usr/local/bin/xfreerdp --version"
                return 1
            fi
            log "    ✓ FreeRDP operational"

            # Build tools must be available for next modules
            for tool in gcc make cmake; do
                if ! command -v "$tool" >/dev/null 2>&1; then
                    error "  ✗ Build tool missing: $tool"
                    return 1
                fi
            done
            log "    ✓ Build tools available"
            ;;

        "02-initramfs")
            # Initramfs file MUST exist and be valid
            local initramfs="$WEB_ROOT/initrds/initrd-minimal.img"
            if [ ! -f "$initramfs" ]; then
                error "  ✗ Initramfs not created at $initramfs"
                return 1
            fi

            # Check size (should be >10MB)
            local size=$(stat -c%s "$initramfs" 2>/dev/null || stat -f%z "$initramfs" 2>/dev/null || echo "0")
            if [ "$size" -lt 10485760 ]; then
                error "  ✗ Initramfs too small: $(($size / 1024 / 1024)) MB (expected >10MB)"
                return 1
            fi
            log "    ✓ Initramfs valid ($(($size / 1024 / 1024)) MB)"

            # Check it's a valid compressed file (supports gzip, zstd, lz4)
            local file_type=$(file "$initramfs")
            local compression_valid=false

            if echo "$file_type" | grep -q "gzip compressed"; then
                log "    ✓ Initramfs is valid gzip archive"
                compression_valid=true
            elif echo "$file_type" | grep -q "Zstandard compressed"; then
                log "    ✓ Initramfs is valid zstd archive"
                compression_valid=true
            elif echo "$file_type" | grep -q "LZ4 compressed"; then
                log "    ✓ Initramfs is valid lz4 archive"
                compression_valid=true
            elif echo "$file_type" | grep -q "data"; then
                # Sometimes compressed files are detected as "data"
                log "    ✓ Initramfs detected (compressed data)"
                compression_valid=true
            fi

            if [ "$compression_valid" = false ]; then
                error "  ✗ Initramfs compression format not recognized"
                error "    File type: $file_type"
                return 1
            fi
            ;;

        "03-web-panel")
            # Python dependencies MUST be importable (only critical packages)
            log "    Checking Python imports..."
            if ! python3 -c "import flask, flask_sqlalchemy, sqlalchemy, cryptography" 2>/dev/null; then
                error "  ✗ Python dependencies not importable"
                error "    Missing: flask, flask-sqlalchemy, sqlalchemy, or cryptography"
                return 1
            fi
            log "    ✓ Python dependencies importable"

            # Database MUST be initialized
            if [ ! -f "/opt/thinclient-manager/db/clients.db" ]; then
                error "  ✗ Database not created"
                return 1
            fi

            # Check database has tables
            local table_count=$(sqlite3 /opt/thinclient-manager/db/clients.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
            if [ "$table_count" -lt 3 ]; then
                error "  ✗ Database has only $table_count tables (expected 5+)"
                return 1
            fi
            log "    ✓ Database initialized with $table_count tables"

            # Nginx MUST be running
            if ! systemctl is-active nginx >/dev/null 2>&1; then
                error "  ✗ Nginx not running after web-panel installation"
                return 1
            fi
            log "    ✓ Nginx is running"

            # Flask app MUST be accessible
            if ! curl -s http://localhost/ | grep -q "Thin-Server\|thin-server\|login" 2>/dev/null; then
                error "  ✗ Flask app not responding on http://localhost/"
                return 1
            fi
            log "    ✓ Flask app is accessible"
            ;;

        "04-boot-config")
            # Kernel MUST be copied
            if [ ! -f "$WEB_ROOT/kernels/vmlinuz" ]; then
                error "  ✗ Kernel not found at $WEB_ROOT/kernels/vmlinuz"
                return 1
            fi
            log "    ✓ Kernel in place"

            # Boot script MUST be generated and valid
            if [ ! -f "$WEB_ROOT/boot.ipxe" ]; then
                error "  ✗ boot.ipxe not created"
                return 1
            fi

            # Check boot.ipxe contains required commands
            if ! grep -q "#!ipxe" "$WEB_ROOT/boot.ipxe"; then
                error "  ✗ boot.ipxe missing iPXE header"
                return 1
            fi
            log "    ✓ boot.ipxe is valid"

            # TFTP MUST be running
            if ! systemctl is-active tftpd-hpa >/dev/null 2>&1; then
                error "  ✗ TFTP service not running"
                return 1
            fi
            log "    ✓ TFTP service is running"

            # iPXE bootloader MUST exist
            if [ ! -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
                error "  ✗ iPXE bootloader missing"
                return 1
            fi
            log "    ✓ iPXE bootloader in place"
            ;;

        "05-maintenance")
            # Maintenance scripts MUST be executable
            if [ ! -x "$SCRIPT_DIR/modules/05-maintenance.sh" ]; then
                error "  ✗ Maintenance script not executable"
                return 1
            fi
            log "    ✓ Maintenance scripts ready"

            # Logrotate config MUST exist
            if [ ! -f "/etc/logrotate.d/thin-server" ]; then
                warn "  ⚠ Logrotate config not created (optional)"
            else
                log "    ✓ Logrotate configured"
            fi
            ;;
    esac

    log "  ✓ Inter-module dependencies satisfied"
    return 0
}

# ============================================
# INSTALL MODULE
# ============================================
install_module() {
    local module_name="$1"
    local is_update="${2:-false}"

    local module_script="$SCRIPT_DIR/modules/$module_name.sh"

    if [ ! -f "$module_script" ]; then
        error "  ✗ Module script not found: $module_script"
        return 1
    fi

    log "Running module installer..."
    local start_time=$(date +%s)

    #Use timestamped temp log for better debugging
    local temp_log="/tmp/module-${module_name}-$(date +%Y%m%d-%H%M%S)-$$.log"

    set +e
    # For maintenance module, explicitly call setup
    if [[ "$module_name" == "05-maintenance" ]]; then
        bash "$module_script" setup > "$temp_log" 2>&1
    else
        bash "$module_script" > "$temp_log" 2>&1
    fi
    local module_exit=$?
    set -e

    # Show module output
    if ! cat "$temp_log" | tee -a "$LOG_FILE"; then
        warn "Failed to display module output, but log saved: $temp_log"
    fi

    log ""
    log "Verifying module installation..."

    #Keep temp log if module failed
    if [ $module_exit -ne 0 ]; then
        error "✗ Module $module_name execution FAILED (exit code: $module_exit)"
        error "  Module log saved: $temp_log"
        error "  Main log: $LOG_FILE"
        error "  DO NOT DELETE temp log - it contains error details!"
        return 1
    fi

    if ! verify_module_files "$module_name"; then
        error "✗ Module $module_name FAILED verification"
        error "  Required files were not created or services not running"
        error "  Module log saved: $temp_log"
        error "  Review the log for details"
        return 1
    fi

    #NEW: Validate inter-module dependencies
    if ! validate_inter_module_dependencies "$module_name"; then
        error "✗ Module $module_name FAILED inter-module dependency check"
        error "  Dependencies for next modules not satisfied"
        error "  Module log saved: $temp_log"
        return 1
    fi

    # Only remove temp log if everything succeeded
    rm -f "$temp_log"

    # Register module
    local clean_module_name="${module_name#[0-9][0-9]-}"
    register_module "$clean_module_name"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "✓ $module_name completed and verified (${duration}s)"
    return 0
}

# ============================================
# SELECT COMPRESSION ALGORITHM
# ============================================
select_compression_algorithm() {
    log ""
    log "╔═══════════════════════════════════════════════════════════════╗"
    log "║          ВИБІР АЛГОРИТМУ СТИСНЕННЯ INITRAMFS                  ║"
    log "╚═══════════════════════════════════════════════════════════════╝"
    log ""
    log "Виберіть алгоритм стиснення для initramfs образів:"
    log ""
    log "  1) pigz -9       (gzip багатопоточний)"
    log "                   • Розмір: стандартний (~93 MB)"
    log "                   • Швидкість створення: швидко (на 70 threads: ~15s)"
    log "                   • Розпакування на клієнті: середнє (~3-4s)"
    log "                   • Сумісність: 100% (працює всюди)"
    log ""
    log "  2) zstd -1       (zstandard швидкий)"
    log "                   • Розмір: добрий (~90 MB, -3%)"
    log "                   • Швидкість створення: дуже швидко (~10s)"
    log "                   • Розпакування на клієнті: швидко (~1-2s)"
    log "                   • Сумісність: kernel 5.9+ (Debian 11+)"
    log ""
    log "  3) zstd -19      (zstandard максимальний) ⭐ РЕКОМЕНДОВАНО"
    log "                   • Розмір: відмінний (~82 MB, -12%)"
    log "                   • Швидкість створення: швидко (~20s)"
    log "                   • Розпакування на клієнті: швидко (~1-2s)"
    log "                   • Сумісність: kernel 5.9+ (Debian 11+)"
    log ""
    log "  4) lz4           (lz4 швидкість превалює)"
    log "                   • Розмір: більший (~115 MB, +24%)"
    log "                   • Швидкість створення: блискавично (~5s)"
    log "                   • Розпакування на клієнті: блискавично (~0.5s)"
    log "                   • Сумісність: kernel 3.11+ (дуже широка)"
    log ""

    local choice=""
    while true; do
        read -p "Ваш вибір (1-4) [3]: " choice
        choice=${choice:-3}

        case "$choice" in
            1)
                export COMPRESSION_ALGO="pigz"
                export COMPRESSION_CMD="pigz -9 -c"
                export DECOMPRESSION_CMD="pigz -dc"
                export COMPRESSION_PKG="pigz"
                log ""
                log "✓ Вибрано: pigz -9 (багатопоточний gzip)"
                break
                ;;
            2)
                export COMPRESSION_ALGO="zstd-fast"
                export COMPRESSION_CMD="zstd -1 -T0 -c"
                export DECOMPRESSION_CMD="zstd -dc"
                export COMPRESSION_PKG="zstd"
                log ""
                log "✓ Вибрано: zstd -1 (швидкий режим)"
                break
                ;;
            3)
                export COMPRESSION_ALGO="zstd"
                export COMPRESSION_CMD="zstd -19 -T0 -c"
                export DECOMPRESSION_CMD="zstd -dc"
                export COMPRESSION_PKG="zstd"
                log ""
                log "✓ Вибрано: zstd -19 (максимальне стиснення)"
                break
                ;;
            4)
                export COMPRESSION_ALGO="lz4"
                export COMPRESSION_CMD="lz4 -1 -c"
                export DECOMPRESSION_CMD="lz4 -dc"
                export COMPRESSION_PKG="liblz4-tool"
                log ""
                log "✓ Вибрано: lz4 (найшвидше розпакування)"
                break
                ;;
            *)
                warn "Невірний вибір! Введіть число від 1 до 4."
                ;;
        esac
    done

    # Save to config in both locations
    # 1. Save to source config (used by modules)
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        sed -i '/^COMPRESSION_ALGO=/d' "$SCRIPT_DIR/config.env"
        sed -i '/^COMPRESSION_CMD=/d' "$SCRIPT_DIR/config.env"
        sed -i '/^DECOMPRESSION_CMD=/d' "$SCRIPT_DIR/config.env"

        cat >> "$SCRIPT_DIR/config.env" << EOF

# ============================================
# СТИСНЕННЯ INITRAMFS (обрано при інсталяції)
# ============================================
COMPRESSION_ALGO="$COMPRESSION_ALGO"
COMPRESSION_CMD="$COMPRESSION_CMD"
DECOMPRESSION_CMD="$DECOMPRESSION_CMD"
EOF
        log "✓ Налаштування збережені в $SCRIPT_DIR/config.env"
    fi

    # 2. Save to /opt/thin-server (used by systemd service)
    if [ -f /opt/thin-server/config.env ]; then
        sed -i '/^COMPRESSION_ALGO=/d' /opt/thin-server/config.env
        sed -i '/^COMPRESSION_CMD=/d' /opt/thin-server/config.env
        sed -i '/^DECOMPRESSION_CMD=/d' /opt/thin-server/config.env

        cat >> /opt/thin-server/config.env << EOF

# ============================================
# СТИСНЕННЯ INITRAMFS (обрано при інсталяції)
# ============================================
COMPRESSION_ALGO="$COMPRESSION_ALGO"
COMPRESSION_CMD="$COMPRESSION_CMD"
DECOMPRESSION_CMD="$DECOMPRESSION_CMD"
EOF
        log "✓ Налаштування збережені в /opt/thin-server/config.env"
    fi

    # Export variables for child processes (critical!)
    export COMPRESSION_ALGO
    export COMPRESSION_CMD
    export DECOMPRESSION_CMD
    export COMPRESSION_PKG

    log "✓ Environment variables exported:"
    log "  COMPRESSION_ALGO=$COMPRESSION_ALGO"
    log "  COMPRESSION_CMD=$COMPRESSION_CMD"
    log "  COMPRESSION_PKG=$COMPRESSION_PKG"

    log ""
}

# ============================================
# INSTALL ALL
# ============================================
install_all() {
    local skip_verification="${1:-false}"

    log ""
    log "╔═══════════════════════════════════════╗"
    log "║   THIN-SERVER INSTALLATION           ║"
    log "╚═══════════════════════════════════════╝"
    log ""
    log "Server: $SERVER_IP"
    log "RDS Server: $RDS_SERVER"
    log "NTP Server: $NTP_SERVER"
    log ""

    #Show warning if skipping verification
    if [ "$skip_verification" = "true" ]; then
        warn "╔═══════════════════════════════════════╗"
        warn "║  ⚠ SKIPPING POST-INSTALL VERIFICATION ║"
        warn "╚═══════════════════════════════════════╝"
        warn ""
        warn "Post-install checks will be SKIPPED"
        warn "This is faster but NOT RECOMMENDED for production"
        warn ""
        sleep 2
    fi

    # Copy config.env to /opt/thin-server for systemd service
    log "Copying config.env and scripts to /opt/thin-server/..."
    mkdir -p /opt/thin-server
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        cp "$SCRIPT_DIR/config.env" /opt/thin-server/config.env
        log "✓ config.env copied to /opt/thin-server/"
    else
        warn "! config.env not found in $SCRIPT_DIR"
    fi

    # Make all scripts executable
    log "Setting execute permissions on scripts..."
    chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/modules/*.sh 2>/dev/null || true
    chmod +x "$SCRIPT_DIR"/scripts/*.sh 2>/dev/null || true
    log "✓ Scripts are now executable"

    #Always ensure time is synced before installation
    if [ -f /tmp/thin-server-time-synced ] && [ "$TIME_SYNC_DONE" = "1" ]; then
        log "✓ System time already synchronized by deploy.sh ($(date))"
    else
        log "Synchronizing system time..."

        # Set timezone
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone Europe/Kyiv 2>/dev/null || ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
        else
            ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
        fi

        # Install ntpdate if needed
        if ! command -v ntpdate &>/dev/null; then
            log "  Installing ntpdate..."
            apt-get install -y -qq ntpdate 2>&1 | tee -a "$LOG_FILE" || warn "Failed to install ntpdate"
        fi

        # Sync time
        local ntp_server="${NTP_SERVER:-pool.ntp.org}"
        if command -v ntpdate &>/dev/null; then
            if ntpdate -u "$ntp_server" 2>&1 | tee -a "$LOG_FILE"; then
                log "✓ Time synced with $ntp_server"
            else
                warn "Failed to sync with $ntp_server, trying pool.ntp.org..."
                if ntpdate -u pool.ntp.org 2>&1 | tee -a "$LOG_FILE"; then
                    log "✓ Time synced with pool.ntp.org"
                else
                    warn "NTP sync failed, continuing anyway"
                fi
            fi
        fi

        # Enable NTP
        if command -v timedatectl &>/dev/null; then
            timedatectl set-ntp true 2>&1 | tee -a "$LOG_FILE" || true
        fi

        log "✓ Current time: $(date)"

        # Mark time sync as done
        export TIME_SYNC_DONE="1"
        echo "TIME_SYNC_DONE=1" > /tmp/thin-server-time-synced

        # Stabilize system after time change
        sleep 2
    fi

    # Select compression algorithm
    select_compression_algorithm

    log ""
    log "This will take 10-15 minutes..."
    log ""

    local install_start=$(date +%s)
    local failed_modules=()
    local success_count=0

    set +e
    for module in "${MODULES[@]}"; do
        if install_module "$module" false; then
            ((success_count++)) || true
        else
            failed_modules+=("$module")

            error ""
            error "═══════════════════════════════════════"
            error "MODULE INSTALLATION FAILED: $module"
            error "═══════════════════════════════════════"
            error ""
            error "Installation cannot continue with failed modules."
            error "Please check the log file: $LOG_FILE"
            error ""

            break
        fi
    done
    set -e

    local install_end=$(date +%s)
    local total_duration=$((install_end - install_start))
    local minutes=$((total_duration / 60))
    local seconds=$((total_duration % 60))

    echo ""
    log "═══════════════════════════════════════"
    log "Installation Summary"
    log "═══════════════════════════════════════"
    log ""
    log "Completed: $success_count/${#MODULES[@]} modules"
    log "Total time: ${minutes}m ${seconds}s"
    
    if [ ${#failed_modules[@]} -eq 0 ]; then
        log ""
        log "╔═══════════════════════════════════════╗"
        log "║  ✓ INSTALLATION COMPLETE              ║"
        log "╚═══════════════════════════════════════╝"
        log ""

        # Run post-install verification
        #Skip verification if requested
        if [ "$skip_verification" = "true" ]; then
            warn ""
            warn "╔═══════════════════════════════════════════════╗"
            warn "║  ⚠ POST-INSTALL VERIFICATION SKIPPED          ║"
            warn "╚═══════════════════════════════════════════════╝"
            warn ""
            warn "Post-install checks were SKIPPED as requested"
            warn "To verify installation manually, run:"
            warn "  bash $SCRIPT_DIR/scripts/verify-installation.sh --post"
            warn "  bash $SCRIPT_DIR/scripts/verify-critical-features.sh"
            warn ""
        else
            section "POST-INSTALL VERIFICATION"
            if [ -f "$SCRIPT_DIR/scripts/verify-installation.sh" ]; then
                log "Running post-install checks..."
                echo ""

                #Capture exit code and handle warnings vs errors
                set +e
                bash "$SCRIPT_DIR/scripts/verify-installation.sh" --post
                local verify_exit=$?
                set -e

                echo ""

                if [ $verify_exit -eq 0 ]; then
                    log "✓ All post-install checks passed"
                elif [ $verify_exit -eq 2 ]; then
                    # Exit code 2 = warnings only (not implemented yet in verify script, but future-proof)
                    warn "╔═══════════════════════════════════════════════╗"
                    warn "║  ⚠ POST-INSTALL COMPLETED WITH WARNINGS       ║"
                    warn "╚═══════════════════════════════════════════════╝"
                    warn ""
                    warn "Some optional components have warnings."
                    warn "Review warnings above - system should work but may have limitations."
                    warn ""
                    log "Installation completed successfully despite warnings"
                else
                    # Exit code 1 = critical errors
                    echo ""
                    error "╔═══════════════════════════════════════════════╗"
                    error "║  ✗ POST-INSTALL VERIFICATION FAILED           ║"
                    error "╚═══════════════════════════════════════════════╝"
                    error ""
                    error "Critical dependencies or components are MISSING!"
                    error "This will cause thin clients to FAIL at boot time."
                    error ""
                    error "See detailed errors above. Common issues:"
                    error "  - Missing libraries (libnsl.so.1, libbpf, etc.)"
                    error "  - Missing binaries (busybox, modprobe, etc.)"
                    error "  - Missing kernel modules (evdev, drm, etc.)"
                    error "  - Missing X.org drivers or modules"
                    error ""
                    error "DO NOT PROCEED - Fix errors first!"
                    error ""

                    # Show log location
                    if [ -n "$LOG_FILE" ]; then
                        error "Full log: $LOG_FILE"
                    fi

                    exit 1
                fi
            else
                warn "verify-installation.sh not found, skipping checks"
            fi

            # Run critical features verification (SSH, RDP parameters, libraries)
            section "CRITICAL FEATURES VERIFICATION"
            if [ -f "$SCRIPT_DIR/scripts/verify-critical-features.sh" ]; then
                log "Running critical features verification..."
                log "  - SSH server (Dropbear) components"
                log "  - RDP parameter parsing and usage"
                log "  - Critical libraries (libbpf.so.1, ALSA, libusb)"
                log "  - Binary dependencies completeness"
                echo ""

                set +e
                bash "$SCRIPT_DIR/scripts/verify-critical-features.sh"
                local features_exit=$?
                set -e

                echo ""

                if [ $features_exit -eq 0 ]; then
                    log "✓ All critical features verified successfully"
                else
                    error "╔═══════════════════════════════════════════════╗"
                    error "║  ✗ CRITICAL FEATURES VERIFICATION FAILED      ║"
                    error "╚═══════════════════════════════════════════════╝"
                    error ""
                    error "One or more critical features have issues:"
                    error "  - SSH server may not work on thin clients"
                    error "  - RDP parameters (sound/printer/USB) may not work"
                    error "  - Missing libraries may cause boot failure"
                    error ""
                    error "See detailed errors above. DO NOT PROCEED!"
                    error ""
                    exit 1
                fi
            else
                warn "verify-critical-features.sh not found, skipping critical features check"
            fi
        fi

        # Generate comprehensive deployment reports
        log ""
        log "📊 Generating deployment reports..."

        REPORTS_SCRIPT="$SCRIPT_DIR/scripts/generate-deployment-reports.sh"
        if [ -f "$REPORTS_SCRIPT" ]; then
            if bash "$REPORTS_SCRIPT"; then
                # Reports generated successfully
                #Check both server and local report directories
                if [ -d "/opt/thin-server/reports" ]; then
                    REPORTS_DIR="/opt/thin-server/reports"
                else
                    REPORTS_DIR="$SCRIPT_DIR/reports"
                fi

                if [ -d "$REPORTS_DIR" ]; then
                    LATEST_REPORT=$(ls -td "$REPORTS_DIR"/*/ 2>/dev/null | head -1)
                    if [ -n "$LATEST_REPORT" ]; then
                        log "✓ Reports generated successfully:"
                        log "  📁 Location: $LATEST_REPORT"
                        log "  📄 Files:"
                        log "     - deployment-validation-report.txt"
                        log "     - installed-packages-report.txt"
                        log "     - initramfs-contents-report.txt"
                        log "     - services-status-report.txt"
                        log "     - system-configuration-report.txt"
                    else
                        log "✓ Reports generated (location: $REPORTS_DIR)"
                    fi
                else
                    log "✓ Reports generated"
                fi
            else
                warn "Report generation failed (non-critical)"
            fi
        else
            warn "Report generation script not found: $REPORTS_SCRIPT"
        fi

        log ""
        log "🌐 Web Panel: http://$SERVER_IP"
        log "👤 Default Login: admin / admin123"
        log ""
        log "⚠️  IMPORTANT NEXT STEPS:"
        log "  1. Change default admin password"
        log "  2. Configure DHCP to point to this server"
        log "  3. Add thin client MAC addresses"
        log ""
        return 0
    else
        error ""
        error "╔═══════════════════════════════════════╗"
        error "║  ✗ ВСТАНОВЛЕННЯ ПРОВАЛИЛОСЬ          ║"
        error "╚═══════════════════════════════════════╝"
        error ""
        error "Модулі що провалились:"
        for module in "${failed_modules[@]}"; do
            error "  ✗ $module"
        done
        error ""
        error "Лог помилок: $LOG_FILE"
        error ""
        error "Рекомендації:"
        error "  1. Перевірте лог файл для деталей"
        error "  2. Виправте помилки"
        error "  3. Запустіть install.sh знову"
        error ""
        
        return 1
    fi
}

# ============================================
# UPDATE MODULE
# ============================================
update_module() {
    local module_name="$1"
    local services_stopped=()

    if [ "$module_name" = "all" ]; then
        log "Updating all modules..."
        for module in "${MODULES[@]}"; do
            if ! update_module "$module"; then
                error "Update failed for $module"
                return 1
            fi
        done
        return 0
    fi

    # Validate module name
    local valid=false
    for module in "${MODULES[@]}"; do
        if [ "$module" = "$module_name" ]; then
            valid=true
            break
        fi
    done

    if [ "$valid" = "false" ]; then
        error "Invalid module: $module_name"
        error "Available modules: ${MODULES[*]}"
        return 1
    fi

    #Stop services before updating critical modules
    case "$module_name" in
        "03-web-panel")
            log "Stopping Flask service before update..."
            if systemctl is-active --quiet thinclient-manager 2>/dev/null; then
                systemctl stop thinclient-manager
                services_stopped+=("thinclient-manager")
                log "  ✓ Flask service stopped"
            fi

            if systemctl is-active --quiet nginx 2>/dev/null; then
                systemctl stop nginx
                services_stopped+=("nginx")
                log "  ✓ Nginx stopped"
            fi
            ;;

        "04-boot-config")
            log "Stopping TFTP service before update..."
            if systemctl is-active --quiet tftpd-hpa 2>/dev/null; then
                systemctl stop tftpd-hpa
                services_stopped+=("tftpd-hpa")
                log "  ✓ TFTP service stopped"
            fi
            ;;
    esac

    # Install module
    local result=0
    install_module "$module_name" true || result=$?

    #Restart stopped services
    if [ ${#services_stopped[@]} -gt 0 ]; then
        log "Restarting services..."
        for service in "${services_stopped[@]}"; do
            systemctl start "$service"
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                log "  ✓ $service restarted"
            else
                error "  ✗ Failed to restart $service"
                result=1
            fi
        done
    fi

    return $result
}

# ============================================
# CHECK STATUS
# ============================================
check_status() {
    clear
    log "╔═══════════════════════════════════════╗"
    log "║   THIN-SERVER SYSTEM STATUS CHECK          ║"
    log "╚═══════════════════════════════════════╝"
    echo ""

    local issues_found=0

    log "Services:"
    check_service "nginx" || ((issues_found++))
    check_service "tftpd-hpa" || ((issues_found++))
    check_service "thinclient-manager" || ((issues_found++))

    echo ""
    log "Files:"

    #Add fix instructions for each missing file
    if [ -f "$WEB_ROOT/boot.ipxe" ]; then
        log "  ✓ boot.ipxe"
    else
        error "  ✗ boot.ipxe MISSING"
        error "     Fix: sudo $0 update 04-boot-config"
        ((issues_found++))
    fi

    if [ -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
        log "  ✓ initramfs"
    else
        error "  ✗ initramfs MISSING"
        error "     Fix: sudo $0 update 02-initramfs"
        ((issues_found++))
    fi

    if [ -f "$WEB_ROOT/kernels/vmlinuz" ]; then
        log "  ✓ kernel"
    else
        error "  ✗ kernel MISSING"
        error "     Fix: sudo $0 update 04-boot-config"
        ((issues_found++))
    fi

    if [ -f "$APP_DIR/app.py" ]; then
        log "  ✓ Flask app"
    else
        error "  ✗ Flask app MISSING"
        error "     Fix: sudo $0 update 03-web-panel"
        ((issues_found++))
    fi

    echo ""
    log "Database:"
    if [ -f "$DB_DIR/clients.db" ]; then
        local client_count=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM client;" 2>/dev/null || echo "0")
        local db_size=$(du -h "$DB_DIR/clients.db" | cut -f1)
        log "  ✓ Database exists ($client_count clients, $db_size)"
    else
        error "  ✗ Database not found"
        error "     Fix: sudo $0 update 03-web-panel"
        ((issues_found++))
    fi

    echo ""
    log "Modules:"
    for module in core-system initramfs web-panel boot-config maintenance; do
        local version=$(get_installed_version "$module")
        if [ "$version" != "0.0.0" ]; then
            log "  ✓ $module v$version"
        else
            error "  ✗ $module not installed"
            # Convert module name to number format
            case "$module" in
                core-system) error "     Fix: sudo $0 update 01-core-system" ;;
                initramfs) error "     Fix: sudo $0 update 02-initramfs" ;;
                web-panel) error "     Fix: sudo $0 update 03-web-panel" ;;
                boot-config) error "     Fix: sudo $0 update 04-boot-config" ;;
                maintenance) error "     Fix: sudo $0 update 05-maintenance" ;;
            esac
            ((issues_found++))
        fi
    done

    echo ""

    #Show summary with fix suggestions
    if [ $issues_found -eq 0 ]; then
        log "╔═══════════════════════════════════════╗"
        log "║  ✓ ALL SYSTEMS OPERATIONAL            ║"
        log "╚═══════════════════════════════════════╝"
        echo ""
        log "Web Panel: http://$SERVER_IP"
        log "TFTP Server: Active on port 69"
    else
        error "╔═══════════════════════════════════════╗"
        error "║  ✗ $issues_found ISSUE(S) FOUND                   ║"
        error "╚═══════════════════════════════════════╝"
        echo ""
        error "Review errors above and run suggested fix commands"
        error "Or reinstall all modules: sudo $0 install"
    fi

    echo ""
}

# ============================================
# MAIN
# ============================================
main() {
    #CRITICAL: Check if running as root
    if [ "$EUID" -ne 0 ]; then
        error "╔═══════════════════════════════════════╗"
        error "║  ✗ ROOT PRIVILEGES REQUIRED           ║"
        error "╚═══════════════════════════════════════╝"
        error ""
        error "This installer must be run with root privileges."
        error "Please run: sudo $0 $*"
        error ""
        exit 1
    fi
    
    # Parse command
    local command="${1:-help}"
    local skip_verification=false

    #Check for --skip-verification flag (use ${2:-} to handle missing $2)
    if [ "${2:-}" = "--skip-verification" ] || [ "$1" = "--skip-verification" ]; then
        skip_verification=true
    fi

    case "$command" in
        install|--skip-verification)
            log "Starting Thin-Server installation..."
            install_all "$skip_verification"
            exit $?
            ;;
            
        update)
            local module="${2:-}"
            if [ -z "$module" ]; then
                error "Usage: $0 update <module|all>"
                error ""
                error "Available modules:"
                for mod in "${MODULES[@]}"; do
                    error "  - $mod"
                done
                error "  - all (update all modules)"
                error ""
                error "Example: $0 update 03-web-panel"
                exit 1
            fi
            update_module "$module"
            exit $?
            ;;
            
        status)
            check_status
            exit 0
            ;;
            
        help|--help|-h)
            usage
            exit 0
            ;;
            
        *)
            error "Unknown command: $command"
            error ""
            usage
            exit 1
            ;;
    esac
}

# ============================================
# RUN MAIN
# ============================================
main "$@"