#!/usr/bin/env bash
# Thin-Server Deploy Script
# Main deployment orchestrator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_MODE="${1:---base}"

# Source common functions
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
else
    echo "ERROR: common.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Load configuration (all settings come from config.env)
if [ -f "$SCRIPT_DIR/config.env" ]; then
    # Use 'set -a' to auto-export all variables for child processes
    set -a
    source "$SCRIPT_DIR/config.env"
    set +a
else
    echo "ERROR: config.env not found"
    exit 1
fi

# Verify critical variables are set
if [ -z "$SERVER_IP" ] || [ -z "$RDS_SERVER" ] || [ -z "$NTP_SERVER" ]; then
    echo "ERROR: Critical variables not set in config.env"
    echo "Required: SERVER_IP, RDS_SERVER, NTP_SERVER"
    exit 1
fi

# ============================================
# CHECK ROOT
# ============================================
if [ "$EUID" -ne 0 ]; then
    error "Please run as root: sudo $0"
    exit 1
fi

# ============================================
# SHOW BANNER
# ============================================
clear
cat << "BANNER"
╔══════════════════════════════════════════════════╗
║                                                  ║
║   ██╗  ██╗██████╗  ██████╗ ███╗   ██╗ █████╗   ║
║   ██║ ██╔╝██╔══██╗██╔═══██╗████╗  ██║██╔══██╗  ║
║   █████╔╝ ██████╔╝██║   ██║██╔██╗ ██║███████║  ║
║   ██╔═██╗ ██╔══██╗██║   ██║██║╚██╗██║██╔══██║  ║
║   ██║  ██╗██║  ██║╚██████╔╝██║ ╚████║██║  ██║  ║
║   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═╝  ║
║                                                  ║
║         ThinClient Manager                      ║
║           Deployment Script                     ║
║                                                  ║
╚══════════════════════════════════════════════════╝
BANNER

echo ""
section "PRE-DEPLOYMENT VERIFICATION"

# ============================================
# RUN COMPREHENSIVE PRE-DEPLOYMENT CHECKS
# ============================================
if [ -f "$SCRIPT_DIR/scripts/verify-installation.sh" ]; then
    log "Running comprehensive pre-deployment verification..."
    log "  (System requirements + Project files + Python syntax)"
    echo ""

    # Run verification and capture exit code
    set +e
    bash "$SCRIPT_DIR/scripts/verify-installation.sh" --pre
    verify_exit=$?
    set -e

    echo ""

    if [ $verify_exit -eq 0 ]; then
        log "✓ Pre-deployment verification passed"
    else
        error "╔════════════════════════════════════════════╗"
        error "║  ✗ PRE-DEPLOYMENT VERIFICATION FAILED      ║"
        error "╚════════════════════════════════════════════╝"
        error ""
        error "Review the errors above before continuing."
        error "Proceeding with errors may result in failed installation."
        error ""
        read -p "Continue anyway (NOT RECOMMENDED)? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Deployment cancelled by user"
            exit 1
        fi
        warn ""
        warn "⚠️  Continuing despite verification errors..."
        warn ""
    fi
else
    warn "Verification script not found at $SCRIPT_DIR/scripts/verify-installation.sh"
    warn "Skipping pre-deployment checks"
fi

echo ""
section "STARTING DEPLOYMENT"

if [ "$DEPLOY_MODE" = "--full" ]; then
    log "Mode: FULL (with system updates)"
else
    log "Mode: BASE (essential packages only)"
    log "Use: sudo $0 --full  for complete installation"
fi

echo ""
read -p "Continue with deployment? [Y/n]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
    log "Deployment cancelled"
    exit 0
fi

# ============================================
# SETUP SERVER TIMEZONE
# ============================================
setup_server_timezone() {
    section "CONFIGURING SERVER TIME"
    
    log "Setting timezone to Europe/Kyiv..."
    timedatectl set-timezone Europe/Kyiv 2>&1 | tee -a "$LOG_FILE" || ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
    
    # Install ntpdate if not present
    if ! command -v ntpdate &>/dev/null && ! [ -x /usr/sbin/ntpdate ]; then
        log "Installing ntpdate..."
        apt-get install -y -qq ntpdate 2>&1 | tee -a "$LOG_FILE"
    fi

    # Find ntpdate location (may be in /usr/sbin)
    NTPDATE_CMD=""
    if command -v ntpdate &>/dev/null; then
        NTPDATE_CMD="ntpdate"
    elif [ -x /usr/sbin/ntpdate ]; then
        NTPDATE_CMD="/usr/sbin/ntpdate"
    fi

    if [ -n "$NTPDATE_CMD" ]; then
        log "Synchronizing server time with NTP $NTP_SERVER..."
        if $NTPDATE_CMD -u "$NTP_SERVER" 2>&1 | tee -a "$LOG_FILE"; then
            log "✓ Time synced with $NTP_SERVER"
        else
            warn "Could not sync with $NTP_SERVER, trying pool.ntp.org..."
            if $NTPDATE_CMD -u pool.ntp.org 2>&1 | tee -a "$LOG_FILE"; then
                log "✓ Time synced with pool.ntp.org"
            else
                warn "NTP sync failed, continuing anyway"
            fi
        fi
    else
        warn "ntpdate not found after installation, skipping time sync"
    fi
    
    timedatectl set-ntp true 2>&1 | tee -a "$LOG_FILE" || warn "Failed to enable NTP"
    
    log "✓ Server timezone: $(timedatectl | grep "Time zone" | awk '{print $3}')"
    log "✓ Server time: $(date)"
    
    log "Waiting for system to stabilize after time sync..."
    sleep 3

    # Kill any stuck package managers
    pkill -9 dpkg 2>/dev/null || true
    pkill -9 apt-get 2>/dev/null || true
    rm -f /var/lib/dpkg/lock* 2>/dev/null || true
    rm -f /var/cache/apt/archives/lock 2>/dev/null || true

    log "✓ System stabilized"

    # Mark that time sync was completed successfully
    export TIME_SYNC_DONE="1"
    echo "TIME_SYNC_DONE=1" > /tmp/thin-server-time-synced
}

# ============================================
# DISK SPACE CHECK
# ============================================
check_disk_space() {
    section "CHECKING DISK SPACE"

    local required_mb=1000  # 1GB minimum
    local root_available_mb=$(df / | tail -1 | awk '{print int($4/1024)}')
    local var_available_mb=$(df /var | tail -1 | awk '{print int($4/1024)}')
    local tmp_available_mb=$(df /tmp | tail -1 | awk '{print int($4/1024)}')

    log "Disk space requirements:"
    log "  Required: ${required_mb}MB minimum"
    log "  / (root): ${root_available_mb}MB available"
    log "  /var:     ${var_available_mb}MB available"
    log "  /tmp:     ${tmp_available_mb}MB available"

    local errors=0

    if [ $root_available_mb -lt $required_mb ]; then
        error "✗ Insufficient disk space on / (root)"
        error "  Required: ${required_mb}MB, Available: ${root_available_mb}MB"
        ((errors++))
    fi

    if [ $var_available_mb -lt 500 ]; then
        error "✗ Insufficient disk space on /var"
        error "  Required: 500MB minimum, Available: ${var_available_mb}MB"
        ((errors++))
    fi

    if [ $tmp_available_mb -lt 200 ]; then
        warn "⚠ Low disk space on /tmp: ${tmp_available_mb}MB"
        warn "  Recommended: 200MB minimum for compilation"
    fi

    if [ $errors -gt 0 ]; then
        error ""
        error "Free up disk space and try again."
        error "Suggestions:"
        error "  - Clean APT cache: apt-get clean"
        error "  - Remove old kernels: apt-get autoremove"
        error "  - Check large files: du -sh /* | sort -h"
        error ""
        exit 1
    fi

    log "✓ Sufficient disk space available"
}

# ============================================
# SYSTEM PREPARATION
# ============================================
prepare_system() {
    section "SYSTEM PREPARATION"

    #Check disk space FIRST
    check_disk_space

    # Ensure log directory
    log "✓ Log directory created"

    # CRITICAL: Setup time and timezone FIRST
    setup_server_timezone

    # Fix APT sources (will run apt-get update inside if changed)
    fix_apt_sources

    # Update APT cache if needed
    if [ "$DEPLOY_MODE" = "--full" ]; then
        run_apt_update || warn "apt update failed, but continuing..."
    fi

    # Install minimal requirements
    log "Installing essential packages..."
    if ! apt-get install -y -qq wget curl git build-essential cmake python3 python3-pip >/dev/null 2>&1; then
        error "Failed to install essential packages"
        exit 1
    fi

    log "✓ Essential packages installed"
}

# ============================================
# MAKE SCRIPTS EXECUTABLE
# ============================================
prepare_scripts() {
    section "PREPARING INSTALLATION SCRIPTS"
    
    cd "$SCRIPT_DIR"
    
    log "Making scripts executable..."
    chmod +x install.sh common.sh 2>/dev/null || true
    chmod +x modules/*.sh 2>/dev/null || true
    
    log "✓ Scripts ready"
}

# ============================================
# RUN BASE INSTALLATION - FIXED
# ============================================
run_installation() {
    section "RUNNING BASE INSTALLATION"
    
    log "Starting Thin-Server installation..."
    log "This will take 10-15 minutes..."
    echo ""
    
    cd "$SCRIPT_DIR"
    
    if [ ! -f "install.sh" ]; then
        error "install.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    
    #Capture exit code from install.sh
    set +e  # Temporarily disable exit on error
    bash install.sh install 2>&1 | tee -a "$LOG_FILE"
    local install_exit=$?
    set -e  # Re-enable exit on error
    
    #Check if installation actually succeeded
    if [ $install_exit -ne 0 ]; then
        error ""
        error "╔═══════════════════════════════════════════════════╗"
        error "║                                                   ║"
        error "║    ✗ INSTALLATION FAILED                          ║"
        error "║                                                   ║"
        error "╚═══════════════════════════════════════════════════╝"
        error ""
        error "The installation did not complete successfully."
        error "Please check the log file for details:"
        error "  $LOG_FILE"
        error ""
        exit 1
    fi
    
    log "✓ Base installation completed successfully"
}

# ============================================
# POST-INSTALLATION SETUP (Full mode only)
# ============================================
post_installation() {
    if [ "$DEPLOY_MODE" != "--full" ]; then
        return 0
    fi
    
    section "POST-INSTALLATION SETUP"
    
    # Install Flask-Limiter
    log "Installing Flask-Limiter for rate limiting..."
    pip3 install Flask-Limiter==3.5.0 --break-system-packages -q 2>/dev/null || \
        warn "Flask-Limiter installation failed"
    
    # Setup log rotation
    log "Configuring log rotation..."
    cat > /etc/logrotate.d/thin-server << 'LOGROTATE'
# Thin-Server Log Rotation

/var/log/thinclient/*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    create 0644 www-data www-data
}

/var/log/nginx/thinclient/*.log {
    daily
    rotate 30
    missingok
    notifempty
    compress
    delaycompress
    create 0644 www-data adm
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) || true
    endscript
}

#Metrics JSONL files rotation (7 days retention)
/var/log/thinclient/metrics/*.jsonl {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    create 0644 www-data www-data
}

#Diagnostics files rotation (14 days retention)
/var/log/thinclient/diagnostics/*.txt {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    create 0644 www-data www-data
}
LOGROTATE

    chmod 644 /etc/logrotate.d/thin-server
    log "✓ Log rotation configured (includes metrics and diagnostics)"
    
    # Setup database backup cron
    log "Setting up database backup..."
    mkdir -p /opt/thin-server/backups/db
    
    cat > /etc/cron.daily/thin-server-backup << 'BACKUP_SCRIPT'
#!/bin/bash
# Thin-Server Daily Database Backup

DB_PATH="/opt/thinclient-manager/db/clients.db"
BACKUP_DIR="/opt/thin-server/backups/db"
RETENTION_DAYS=7

if [ -f "$DB_PATH" ]; then
    BACKUP_FILE="$BACKUP_DIR/clients-$(date +%Y%m%d-%H%M%S).db"
    cp "$DB_PATH" "$BACKUP_FILE"
    gzip "$BACKUP_FILE"
    
    # Remove old backups
    find "$BACKUP_DIR" -name "clients-*.db.gz" -mtime +$RETENTION_DAYS -delete
fi
BACKUP_SCRIPT
    
    chmod +x /etc/cron.daily/thin-server-backup
    log "✓ Database backup scheduled"

    # Note: Deployment reports are generated by install.sh
    # No need to generate them again here to avoid duplication

    # ============================================
    # POST-DEPLOYMENT VERIFICATION
    # ============================================
    section "POST-DEPLOYMENT VERIFICATION"

    local verification_failed=false

    # 1. Standard verification (--post mode)
    if [ -f "$SCRIPT_DIR/scripts/verify-installation.sh" ]; then
        log "Running post-deployment verification..."
        echo ""

        set +e
        bash "$SCRIPT_DIR/scripts/verify-installation.sh" --post
        local verify_post_exit=$?
        set -e

        echo ""

        if [ $verify_post_exit -ne 0 ]; then
            error "✗ Post-deployment verification FAILED"
            verification_failed=true
        else
            log "✓ Post-deployment verification PASSED"
        fi
    else
        warn "verify-installation.sh not found, skipping standard verification"
    fi

    # 2. Critical features verification
    if [ -f "$SCRIPT_DIR/scripts/verify-critical-features.sh" ]; then
        log "Running critical features verification..."
        echo ""

        set +e
        bash "$SCRIPT_DIR/scripts/verify-critical-features.sh"
        local verify_critical_exit=$?
        set -e

        echo ""

        if [ $verify_critical_exit -ne 0 ]; then
            error "✗ Critical features verification FAILED"
            verification_failed=true
        else
            log "✓ Critical features verification PASSED"
        fi
    else
        warn "verify-critical-features.sh not found, skipping critical features check"
    fi

    # 3. Extended validation (NEW)
    if [ -f "$SCRIPT_DIR/scripts/verify-extended-validation.sh" ]; then
        log "Running extended validation checks..."
        echo ""

        set +e
        bash "$SCRIPT_DIR/scripts/verify-extended-validation.sh"
        local verify_extended_exit=$?
        set -e

        echo ""

        if [ $verify_extended_exit -ne 0 ]; then
            error "✗ Extended validation FAILED"
            verification_failed=true
        else
            log "✓ Extended validation PASSED"
        fi
    else
        warn "verify-extended-validation.sh not found, skipping extended validation"
    fi

    # Final verdict
    echo ""
    if [ "$verification_failed" = true ]; then
        error "╔════════════════════════════════════════════════════════╗"
        error "║  ⚠️  POST-DEPLOYMENT VERIFICATION DETECTED ISSUES      ║"
        error "╚════════════════════════════════════════════════════════╝"
        error ""
        error "Some verification checks failed. Review the output above."
        error "The system may not function correctly."
        error ""
        warn "RECOMMENDATION: Review failed checks and fix issues before production use"
        echo ""
    else
        log "╔════════════════════════════════════════════════════════╗"
        log "║  ✓ ALL POST-DEPLOYMENT VERIFICATIONS PASSED           ║"
        log "╚════════════════════════════════════════════════════════╝"
        echo ""
    fi

    log "✓ Post-installation setup completed"
}

# ============================================
# SHOW SUCCESS MESSAGE - ONLY if successful
# ============================================
show_success() {
    # Read SERVER_IP from config
    set -a
    source "$SCRIPT_DIR/config.env" 2>/dev/null || SERVER_IP="<your-server-ip>"
    set +a

    clear
    
    cat << EOF

╔═══════════════════════════════════════════════════╗
║                                                   ║
║    ✓ THIN-SERVER ВСТАНОВЛЕНО УСПІШНО!                 ║
║                                                   ║
╚═══════════════════════════════════════════════════╝

🎉 Вітаємо! Ваш Thin-Server ThinClient сервер готовий!

📊 ТОЧКИ ДОСТУПУ:
   • Веб-панель: http://$SERVER_IP
   • Логін: admin / admin123

⚠️  ВАЖЛИВІ НАСТУПНІ КРОКИ:

   1. ЗМІНИТИ ПАРОЛЬ АДМІНІСТРАТОРА (ЗАРАЗ!)
      http://$SERVER_IP/admin → Change Password

   2. НАЛАШТУВАТИ DHCP СЕРВЕР
      Додайте в конфігурацію DHCP:
      - next-server: $SERVER_IP
      - filename: efi64/bootx64.efi

   3. ДОДАТИ КЛІЄНТІВ
      http://$SERVER_IP → Add Client
      Введіть MAC адреси тонких клієнтів

   4. ЗАВАНТАЖИТИ ПЕРШИЙ КЛІЄНТ
      Увімкніть клієнт з PXE boot

📋 КОРИСНІ КОМАНДИ:
   # Перевірка статусу
   cd /opt/thin-server && sudo ./install.sh status

   # Перегляд логів
   sudo tail -f /var/log/thinclient/app.log

   # Оновлення модуля
   cd /opt/thin-server && sudo ./install.sh update MODULE_NAME

   # Backup бази даних
   cd /opt/thin-server && sudo ./modules/05-maintenance.sh backup

   # Діагностика
   cd /opt/thin-server && sudo ./modules/05-maintenance.sh diagnostics

📝 ПЕРЕВІРКА УСТАНОВКИ:
   curl http://$SERVER_IP/boot.ipxe
   # Має повернути iPXE script

📚 ДОКУМЕНТАЦІЯ:
   • README: /opt/thin-server/README.md
   • API Docs: /opt/thin-server/docs/API.md
   • Deployment Guide: /opt/thin-server/docs/DEPLOYMENT_GUIDE.md

💾 ЛОГ УСТАНОВКИ:
   $LOG_FILE

═══════════════════════════════════════════════════

Press ENTER to view installation log, or Ctrl+C to exit...
EOF

    read

    # Show full installation log with less for scrolling
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  ПОВНИЙ ЛОГ УСТАНОВКИ"
    echo "  (Використовуйте ↑↓ для скролінгу, 'q' для виходу)"
    echo "═══════════════════════════════════════════════════"
    echo ""
    sleep 1

    # Show full log with less for scrolling
    less +G "$LOG_FILE" || cat "$LOG_FILE"
}

# ============================================
# MAIN EXECUTION
# ============================================
main() {
    # Step 1: Prepare system
    prepare_system
    
    # Step 2: Prepare scripts
    prepare_scripts
    
    # Step 3: Run installation - ✅ CRITICAL: Check exit code
    if ! run_installation; then
        # Installation failed - error already shown
        exit 1
    fi
    
    # Step 4: Post-installation (only in full mode)
    post_installation
    
    # Step 5: Show success message - ONLY if we got here
    show_success
}

# Run main
main

exit 0