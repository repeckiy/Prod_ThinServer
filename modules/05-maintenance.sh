#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

MODULE_NAME="maintenance"
MODULE_VERSION="$APP_VERSION"

BACKUP_DIR="${BACKUP_DIR:-/opt/thin-server/backups}"
MAINTENANCE_LOG="/var/log/thinclient/maintenance.log"

# Ensure maintenance log exists
ensure_dir "$(dirname "$MAINTENANCE_LOG")" 755
touch "$MAINTENANCE_LOG"
chmod 644 "$MAINTENANCE_LOG"

# Override log function to also write to maintenance log
maintenance_log() {
    local message="$1"
    # Write to standard log
    log "$message"
    # Also write to maintenance log with timestamp
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$MAINTENANCE_LOG"
}

log "═══════════════════════════════════════"
log "Maintenance Module v$MODULE_VERSION"
log "═══════════════════════════════════════"

# ============================================
# VALIDATE MAINTENANCE ENVIRONMENT
# ============================================
validate_maintenance_environment() {
    maintenance_log "Validating maintenance environment..."

    local validation_ok=true

    #Check required commands
    log "  Checking required tools..."

    local required_tools=(
        "sqlite3:SQLite database tool"
        "tar:Archive tool"
        "gzip:Compression tool"
        "logrotate:Log rotation tool"
        "find:File search tool"
        "cron:Task scheduler"
    )

    for tool_spec in "${required_tools[@]}"; do
        local tool="${tool_spec%%:*}"
        local description="${tool_spec#*:}"

        if command -v "$tool" >/dev/null 2>&1; then
            local version=""
            case "$tool" in
                sqlite3)
                    version=$(sqlite3 --version 2>&1 | awk '{print $1}')
                    ;;
                tar)
                    version=$(tar --version 2>&1 | head -1 | awk '{print $NF}')
                    ;;
                logrotate)
                    version=$(logrotate --version 2>&1 | head -1 | awk '{print $2}')
                    ;;
            esac

            if [ -n "$version" ]; then
                log "    ✓ $tool v$version ($description)"
            else
                log "    ✓ $tool ($description)"
            fi
        else
            warn "    ⚠ $tool NOT FOUND ($description) - attempting to install..."

            # Try to install missing tool
            case "$tool" in
                logrotate)
                    if apt-get install -y logrotate 2>&1 | tee -a "$LOG_FILE"; then
                        log "      ✓ logrotate installed"
                    else
                        error "      ✗ Failed to install logrotate"
                        validation_ok=false
                    fi
                    ;;
                cron)
                    if apt-get install -y cron 2>&1 | tee -a "$LOG_FILE"; then
                        log "      ✓ cron installed"
                        # Enable and start cron service
                        systemctl enable cron 2>/dev/null || true
                        systemctl start cron 2>/dev/null || true
                    else
                        error "      ✗ Failed to install cron"
                        validation_ok=false
                    fi
                    ;;
                *)
                    error "    ✗ $tool NOT FOUND and cannot auto-install"
                    validation_ok=false
                    ;;
            esac
        fi
    done

    #Check critical directories
    log "  Checking critical directories..."

    local critical_dirs=(
        "$BACKUP_DIR:Backup storage"
        "$DB_DIR:Database directory"
        "$LOG_DIR:Log directory"
        "/var/log/thinclient:ThinClient logs"
    )

    for dir_spec in "${critical_dirs[@]}"; do
        local dir="${dir_spec%%:*}"
        local description="${dir_spec#*:}"

        if [ -d "$dir" ]; then
            local space_avail=$(df -h "$dir" | tail -1 | awk '{print $4}')
            log "    ✓ $dir ($description) - ${space_avail} available"
        else
            warn "    ⚠ $dir ($description) - creating..."
            ensure_dir "$dir" 755
        fi
    done

    #Check database exists and is accessible
    log "  Checking database..."

    if [ -f "$DB_DIR/clients.db" ]; then
        local db_size=$(du -h "$DB_DIR/clients.db" | cut -f1)
        log "    ✓ Database file exists (${db_size})"

        # Check database integrity
        local integrity=$(sqlite3 "$DB_DIR/clients.db" "PRAGMA integrity_check;" 2>&1)
        if [ "$integrity" = "ok" ]; then
            log "    ✓ Database integrity: OK"
        else
            error "    ✗ Database integrity check FAILED"
            error "      $integrity"
            validation_ok=false
        fi

        # Check database permissions
        if [ -r "$DB_DIR/clients.db" ] && [ -w "$DB_DIR/clients.db" ]; then
            log "    ✓ Database permissions: OK (read/write)"
        else
            error "    ✗ Database permissions incorrect"
            validation_ok=false
        fi
    else
        warn "    ⚠ Database not found (will be created by web-panel module)"
    fi

    #Check disk space
    log "  Checking disk space..."

    local root_avail_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "$root_avail_gb" -lt 2 ]; then
        error "    ✗ Low disk space: ${root_avail_gb}GB (need at least 2GB)"
        validation_ok=false
    else
        log "    ✓ Disk space: ${root_avail_gb}GB available"
    fi

    #Check cron service
    log "  Checking cron service..."

    if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
        log "    ✓ Cron service is running"
    else
        error "    ✗ Cron service is NOT running"
        validation_ok=false
    fi

    if [ "$validation_ok" = false ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ MAINTENANCE ENVIRONMENT VALIDATION FAILED  ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Maintenance tasks cannot run without required tools."
        error "Please fix the issues above before proceeding."
        return 1
    fi

    maintenance_log "✓ Maintenance environment validation passed"
    return 0
}

# ============================================
# SETUP LOGROTATE (30 DAYS RETENTION)
# ============================================
setup_logrotate() {
    maintenance_log "Setting up logrotate for automatic log rotation (30 days)..."

    #Create logrotate configuration for all Thin-Server logs
    log "  Creating logrotate configuration..."

    cat > /etc/logrotate.d/thin-server << 'EOF'
# Thin-Server ThinClient Manager - Log Rotation Configuration
# Автоматична ротація всіх логів з retention 30 днів

# ThinClient application logs
/var/log/thinclient/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
    sharedscripts
    postrotate
        systemctl reload thinclient-manager >/dev/null 2>&1 || true
    endscript
}

# Nginx ThinClient logs
/var/log/nginx/thinclient/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 www-data www-data
    sharedscripts
    postrotate
        systemctl reload nginx >/dev/null 2>&1 || true
    endscript
}

# Thin-Server system logs
/var/log/thin-server-*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}

# Maintenance logs
/var/log/thinclient/maintenance.log {
    daily
    rotate 60
    compress
    delaycompress
    missingok
    notifempty
    create 0644 root root
}
EOF

    if [ ! -f /etc/logrotate.d/thin-server ]; then
        error "  ✗ Failed to create logrotate configuration"
        return 1
    fi

    local config_size=$(stat -f%z /etc/logrotate.d/thin-server 2>/dev/null || stat -c%s /etc/logrotate.d/thin-server 2>/dev/null)
    log "    ✓ Logrotate config created (${config_size} bytes)"

    #Test logrotate configuration
    log "  Testing logrotate configuration..."

    if logrotate -d /etc/logrotate.d/thin-server 2>&1 | grep -q "error"; then
        error "    ✗ Logrotate configuration test FAILED"
        logrotate -d /etc/logrotate.d/thin-server 2>&1 | grep "error"
        return 1
    fi

    log "    ✓ Logrotate configuration valid"

    #Force initial rotation to test
    log "  Running initial log rotation test..."

    if logrotate -f /etc/logrotate.d/thin-server 2>&1 | grep -i "error"; then
        warn "    ⚠ Initial rotation had warnings (but config is valid)"
    else
        log "    ✓ Initial rotation successful"
    fi

    maintenance_log "✓ Logrotate configured successfully"
    maintenance_log "  Retention: 30 days for application logs, 60 days for maintenance logs"
    maintenance_log "  Compression: enabled (delayed)"
    maintenance_log "  Frequency: daily"

    return 0
}

# ============================================
# SETUP DATABASE BACKUP (щоденно о 2 ночі)
# ============================================
setup_db_backup() {
    maintenance_log "Setting up automatic database backup..."

    #Verify backup script exists
    log "  Checking backup script..."

    local backup_script="/opt/thin-server/scripts/backup-db.sh"
    local source_script="$SCRIPT_DIR/../scripts/backup-db.sh"

    # Ensure directory exists
    mkdir -p "$(dirname "$backup_script")"

    if [ -f "$backup_script" ]; then
        log "    ✓ Backup script exists"

        # Check if script is executable
        if [ -x "$backup_script" ]; then
            log "    ✓ Backup script is executable"
        else
            warn "    ⚠ Making backup script executable..."
            chmod +x "$backup_script"
        fi
    else
        warn "    ⚠ Backup script not found - copying from source..."

        if [ -f "$source_script" ]; then
            if cp "$source_script" "$backup_script" 2>&1 | tee -a "$LOG_FILE"; then
                chmod +x "$backup_script"
                log "    ✓ Backup script copied and made executable"
            else
                error "    ✗ Failed to copy backup script"
                return 1
            fi
        else
            error "    ✗ Source backup script not found: $source_script"
            return 1
        fi
    fi

    #Create cron job for backup at 2 AM
    log "  Creating cron job..."

    cat > /etc/cron.d/thin-server-db-backup << 'EOF'
# Thin-Server Database Backup with Integrity Check
# Runs daily at 2:00 AM, keeps backups for 7 days
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Minute Hour Day Month Weekday Command
0 2 * * * root /opt/thin-server/scripts/backup-db.sh backup >> /var/log/thinclient/maintenance.log 2>&1
EOF

    if [ ! -f /etc/cron.d/thin-server-db-backup ]; then
        error "  ✗ Failed to create cron job"
        return 1
    fi

    chmod 644 /etc/cron.d/thin-server-db-backup
    log "    ✓ Cron job created"

    #Verify cron job syntax
    log "  Verifying cron job..."

    if grep -q "backup-db.sh" /etc/cron.d/thin-server-db-backup; then
        log "    ✓ Cron job configured correctly"
    else
        error "    ✗ Cron job verification failed"
        cat /etc/cron.d/thin-server-db-backup 2>&1 | head -5 | tee -a "$LOG_FILE" || true
        return 1
    fi

    maintenance_log "✓ Database backup scheduled successfully"
    maintenance_log "  Schedule: Daily at 2:00 AM"
    maintenance_log "  Retention: 7 days"
    maintenance_log "  Log: /var/log/thinclient/maintenance.log"

    return 0
}

# ============================================
# SETUP DATABASE CLEANUP (cron daily)
# ============================================
setup_database_cleanup() {
    maintenance_log "Setting up automatic database cleanup..."

    #Create cron job for database maintenance
    log "  Creating database cleanup cron job..."

    cat > /etc/cron.daily/thin-server-db-cleanup << 'EOF'
#!/bin/bash
# Thin-Server Database Cleanup and Maintenance
# Runs daily to clean old database entries and optimize

MAINTENANCE_LOG="/var/log/thinclient/maintenance.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting database cleanup..." >> "$MAINTENANCE_LOG"

# Clean database logs (30 days retention)
if [ -f /opt/thinclient-manager/db/clients.db ]; then
    # Delete old client logs
    deleted_client_logs=$(sqlite3 /opt/thinclient-manager/db/clients.db \
        "SELECT COUNT(*) FROM client_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || echo "0")

    sqlite3 /opt/thinclient-manager/db/clients.db \
        "DELETE FROM client_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true

    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Deleted $deleted_client_logs client log entries" >> "$MAINTENANCE_LOG"

    # Delete old audit logs
    deleted_audit_logs=$(sqlite3 /opt/thinclient-manager/db/clients.db \
        "SELECT COUNT(*) FROM audit_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || echo "0")

    sqlite3 /opt/thinclient-manager/db/clients.db \
        "DELETE FROM audit_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true

    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Deleted $deleted_audit_logs audit log entries" >> "$MAINTENANCE_LOG"

    # Vacuum to reclaim space
    db_size_before=$(du -h /opt/thinclient-manager/db/clients.db | cut -f1)
    sqlite3 /opt/thinclient-manager/db/clients.db "VACUUM;" 2>/dev/null || true
    db_size_after=$(du -h /opt/thinclient-manager/db/clients.db | cut -f1)

    echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Database optimized: $db_size_before → $db_size_after" >> "$MAINTENANCE_LOG"

    # Integrity check
    integrity=$(sqlite3 /opt/thinclient-manager/db/clients.db "PRAGMA integrity_check;" 2>&1)
    if [ "$integrity" = "ok" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Database integrity: OK" >> "$MAINTENANCE_LOG"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   ERROR: Database integrity check FAILED: $integrity" >> "$MAINTENANCE_LOG"
    fi
fi

# Clean old backups (keep last 10)
if [ -d /opt/thin-server/backups ]; then
    backup_count=$(ls -1 /opt/thin-server/backups | wc -l)
    if [ "$backup_count" -gt 10 ]; then
        cd /opt/thin-server/backups
        removed_count=$(ls -t | tail -n +11 | wc -l)
        ls -t | tail -n +11 | xargs rm -rf 2>/dev/null || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Removed $removed_count old backup(s), kept last 10" >> "$MAINTENANCE_LOG"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Database cleanup completed" >> "$MAINTENANCE_LOG"
EOF

    if [ ! -f /etc/cron.daily/thin-server-db-cleanup ]; then
        error "  ✗ Failed to create database cleanup cron job"
        return 1
    fi

    chmod +x /etc/cron.daily/thin-server-db-cleanup
    log "    ✓ Database cleanup cron job created"

    #Test the script syntax
    log "  Testing cleanup script syntax..."

    if bash -n /etc/cron.daily/thin-server-db-cleanup 2>/dev/null; then
        log "    ✓ Cleanup script syntax valid"
    else
        error "    ✗ Cleanup script has syntax errors"
        bash -n /etc/cron.daily/thin-server-db-cleanup 2>&1
        return 1
    fi

    maintenance_log "✓ Database cleanup scheduled successfully"
    maintenance_log "  Schedule: Daily (cron.daily)"
    maintenance_log "  Retention: 30 days for logs"
    maintenance_log "  Backups: Keep last 10"
    maintenance_log "  Features: Vacuum, integrity check"

    return 0
}

# ============================================
# BACKUP SYSTEM WITH INTEGRITY CHECKS
# ============================================
backup_system() {
    maintenance_log "Creating system backup with integrity validation..."

    ensure_dir "$BACKUP_DIR" 755

    local backup_name="thin-server-backup-$(date +%Y%m%d-%H%M%S)"
    local backup_path="$BACKUP_DIR/$backup_name"

    local backup_ok=true

    #STEP 1: Pre-backup validation
    log "  Running pre-backup validation..."

    # Check available disk space
    local backup_dir_avail_mb=$(df -BM "$BACKUP_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')
    if [ "$backup_dir_avail_mb" -lt 100 ]; then
        error "    ✗ Insufficient disk space for backup: ${backup_dir_avail_mb}MB"
        return 1
    fi
    log "    ✓ Disk space available: ${backup_dir_avail_mb}MB"

    # Check database integrity BEFORE backup
    if [ -f "$DB_DIR/clients.db" ]; then
        log "    Checking database integrity..."
        local integrity=$(sqlite3 "$DB_DIR/clients.db" "PRAGMA integrity_check;" 2>&1)
        if [ "$integrity" = "ok" ]; then
            log "    ✓ Database integrity: OK"
        else
            error "    ✗ Database integrity check FAILED: $integrity"
            error "    Cannot backup corrupted database!"
            return 1
        fi
    fi

    mkdir -p "$backup_path"

    #STEP 2: Backup configuration
    log "  Backing up configuration files..."

    local config_files=(
        "$THINSERVER_ROOT/config.env:config.env"
        "$THINSERVER_ROOT/.versions:.versions"
    )

    local config_count=0
    for file_spec in "${config_files[@]}"; do
        local source="${file_spec%%:*}"
        local dest="${file_spec#*:}"

        if [ -f "$source" ]; then
            if cp -a "$source" "$backup_path/$dest" 2>/dev/null; then
                local size=$(stat -f%z "$backup_path/$dest" 2>/dev/null || stat -c%s "$backup_path/$dest" 2>/dev/null)
                log "    ✓ $dest ($size bytes)"
                ((config_count++))
            else
                warn "    ⚠ Failed to backup $dest"
            fi
        else
            warn "    ⚠ $dest not found, skipping"
        fi
    done

    log "    Backed up $config_count configuration file(s)"

    #STEP 3: Backup database with verification
    log "  Backing up database..."

    if [ -f "$DB_DIR/clients.db" ]; then
        local db_size_before=$(stat -f%z "$DB_DIR/clients.db" 2>/dev/null || stat -c%s "$DB_DIR/clients.db" 2>/dev/null)

        # Use SQLite .backup command for safe backup
        if sqlite3 "$DB_DIR/clients.db" ".backup '$backup_path/clients.db'" 2>/dev/null; then
            local db_size_after=$(stat -f%z "$backup_path/clients.db" 2>/dev/null || stat -c%s "$backup_path/clients.db" 2>/dev/null)

            if [ "$db_size_before" -eq "$db_size_after" ]; then
                log "    ✓ Database backed up ($(du -h "$backup_path/clients.db" | cut -f1))"

                # Verify backup integrity
                local backup_integrity=$(sqlite3 "$backup_path/clients.db" "PRAGMA integrity_check;" 2>&1)
                if [ "$backup_integrity" = "ok" ]; then
                    log "    ✓ Backup database integrity: OK"
                else
                    error "    ✗ Backup database corrupted: $backup_integrity"
                    backup_ok=false
                fi
            else
                error "    ✗ Database backup size mismatch"
                backup_ok=false
            fi
        else
            error "    ✗ Database backup FAILED"
            backup_ok=false
        fi

        # Get database statistics
        if [ "$backup_ok" = true ]; then
            local client_count=$(sqlite3 "$backup_path/clients.db" "SELECT COUNT(*) FROM client;" 2>/dev/null || echo "0")
            local log_count=$(sqlite3 "$backup_path/clients.db" "SELECT COUNT(*) FROM client_log;" 2>/dev/null || echo "0")
            log "    Database contains: $client_count clients, $log_count logs"
        fi
    else
        warn "    ⚠ Database not found, skipping"
    fi

    #STEP 4: Backup Flask application
    log "  Backing up Flask application..."

    local app_files=(
        "$APP_DIR/app.py:app.py"
        "$APP_DIR/config.py:config.py"
        "$APP_DIR/models.py:models.py"
        "$APP_DIR/utils.py:utils.py"
    )

    local app_count=0
    for file_spec in "${app_files[@]}"; do
        local source="${file_spec%%:*}"
        local dest="${file_spec#*:}"

        if [ -f "$source" ]; then
            if cp -a "$source" "$backup_path/" 2>/dev/null; then
                ((app_count++))
            fi
        fi
    done

    log "    ✓ Backed up $app_count Flask file(s)"

    # Backup templates
    if [ -d "$APP_DIR/templates" ]; then
        if cp -a "$APP_DIR/templates" "$backup_path/" 2>/dev/null; then
            local template_count=$(find "$backup_path/templates" -name "*.html" | wc -l)
            log "    ✓ Backed up templates ($template_count files)"
        fi
    fi

    #STEP 5: Backup Nginx configuration
    log "  Backing up Nginx configuration..."

    if [ -f /etc/nginx/sites-available/thinclient ]; then
        if cp -a /etc/nginx/sites-available/thinclient "$backup_path/nginx-thinclient" 2>/dev/null; then
            log "    ✓ Nginx config backed up"
        else
            warn "    ⚠ Failed to backup Nginx config"
        fi
    else
        warn "    ⚠ Nginx config not found"
    fi

    #STEP 6: Backup systemd service
    log "  Backing up systemd service..."

    if [ -f /etc/systemd/system/thinclient-manager.service ]; then
        if cp -a /etc/systemd/system/thinclient-manager.service "$backup_path/" 2>/dev/null; then
            log "    ✓ Systemd service backed up"
        else
            warn "    ⚠ Failed to backup systemd service"
        fi
    else
        warn "    ⚠ Systemd service not found"
    fi

    #STEP 7: Create backup manifest
    log "  Creating backup manifest..."

    cat > "$backup_path/backup-info.txt" << EOF
Thin-Server ThinClient Manager - Backup Information
===============================================
Created: $(date '+%Y-%m-%d %H:%M:%S')
Hostname: $(hostname)
Server IP: ${SERVER_IP:-N/A}
RDS Server: ${RDS_SERVER:-N/A}
NTP Server: ${NTP_SERVER:-N/A}

System Information:
-------------------
OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
Kernel: $(uname -r)
Architecture: $(uname -m)

Module Versions:
----------------
$(cat "$THINSERVER_ROOT/.versions" 2>/dev/null || echo "No version information available")

Database Statistics:
--------------------
$(if [ -f "$backup_path/clients.db" ]; then
    sqlite3 "$backup_path/clients.db" "SELECT COUNT(*) || ' total clients' FROM client;" 2>/dev/null
    sqlite3 "$backup_path/clients.db" "SELECT COUNT(*) || ' client logs' FROM client_log;" 2>/dev/null
    sqlite3 "$backup_path/clients.db" "SELECT COUNT(*) || ' audit logs' FROM audit_log;" 2>/dev/null
    echo "Database size: $(du -h "$backup_path/clients.db" | cut -f1)"
else
    echo "Database not included in backup"
fi)

Backup Contents:
----------------
Total files: $(find "$backup_path" -type f | wc -l)
Backup size (uncompressed): $(du -sh "$backup_path" | cut -f1)

Backup Integrity:
-----------------
Database integrity: $(if [ -f "$backup_path/clients.db" ]; then sqlite3 "$backup_path/clients.db" "PRAGMA integrity_check;" 2>&1; else echo "N/A"; fi)

Created by: Thin-Server Maintenance Module v$MODULE_VERSION
EOF

    log "    ✓ Backup manifest created"

    if [ "$backup_ok" = false ]; then
        error "  ✗ Backup completed with ERRORS"
        error "    Check backup at: $backup_path"
        return 1
    fi

    #STEP 8: Compress backup
    log "  Compressing backup..."

    cd "$BACKUP_DIR"

    local files_before=$(find "$backup_name" -type f | wc -l)

    if tar czf "${backup_name}.tar.gz" "$backup_name" 2>/dev/null; then
        log "    ✓ Backup compressed"

        # Verify archive
        if tar tzf "${backup_name}.tar.gz" >/dev/null 2>&1; then
            local files_in_archive=$(tar tzf "${backup_name}.tar.gz" | wc -l)
            log "    ✓ Archive verified ($files_in_archive entries)"

            # Remove uncompressed backup
            rm -rf "$backup_name"

            local archive_size=$(du -h "${backup_name}.tar.gz" | cut -f1)
            maintenance_log "✓ Backup created successfully: ${backup_name}.tar.gz ($archive_size)"

            echo "$BACKUP_DIR/${backup_name}.tar.gz"
            return 0
        else
            error "    ✗ Archive verification FAILED"
            rm -f "${backup_name}.tar.gz"
            return 1
        fi
    else
        error "    ✗ Compression FAILED"
        return 1
    fi
}

# ============================================
# VERIFY BACKUP
# ============================================
verify_backup() {
    local backup_file="$1"

    if [ -z "$backup_file" ]; then
        error "Usage: $0 verify <backup-file>"
        return 1
    fi

    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
        return 1
    fi

    maintenance_log "Verifying backup: $(basename "$backup_file")"

    local verification_ok=true

    #STEP 1: Check archive integrity
    log "  Checking archive integrity..."

    if tar tzf "$backup_file" >/dev/null 2>&1; then
        local entries=$(tar tzf "$backup_file" | wc -l)
        log "    ✓ Archive is valid ($entries entries)"
    else
        error "    ✗ Archive is CORRUPTED or invalid"
        return 1
    fi

    #STEP 2: Extract to temp directory
    log "  Extracting to temporary location..."

    local verify_dir="/tmp/thin-server-verify-$$"
    mkdir -p "$verify_dir"

    if tar xzf "$backup_file" -C "$verify_dir" 2>/dev/null; then
        log "    ✓ Archive extracted successfully"
    else
        error "    ✗ Extraction FAILED"
        rm -rf "$verify_dir"
        return 1
    fi

    local backup_name=$(basename "$backup_file" .tar.gz)
    local extract_path="$verify_dir/$backup_name"

    #STEP 3: Verify backup manifest
    log "  Verifying backup manifest..."

    if [ -f "$extract_path/backup-info.txt" ]; then
        log "    ✓ Backup manifest exists"
        log "      $(head -1 "$extract_path/backup-info.txt")"
    else
        warn "    ⚠ Backup manifest missing"
    fi

    #STEP 4: Verify database
    log "  Verifying database..."

    if [ -f "$extract_path/clients.db" ]; then
        local db_size=$(du -h "$extract_path/clients.db" | cut -f1)
        log "    ✓ Database file exists ($db_size)"

        # Check database integrity
        local integrity=$(sqlite3 "$extract_path/clients.db" "PRAGMA integrity_check;" 2>&1)
        if [ "$integrity" = "ok" ]; then
            log "    ✓ Database integrity: OK"

            # Get database statistics
            local clients=$(sqlite3 "$extract_path/clients.db" "SELECT COUNT(*) FROM client;" 2>/dev/null || echo "0")
            local logs=$(sqlite3 "$extract_path/clients.db" "SELECT COUNT(*) FROM client_log;" 2>/dev/null || echo "0")
            log "    Database contains: $clients clients, $logs logs"
        else
            error "    ✗ Database integrity check FAILED: $integrity"
            verification_ok=false
        fi
    else
        warn "    ⚠ Database not found in backup"
    fi

    #STEP 5: Verify configuration files
    log "  Verifying configuration files..."

    local config_files=("config.env" ".versions")
    for file in "${config_files[@]}"; do
        if [ -f "$extract_path/$file" ]; then
            local size=$(stat -f%z "$extract_path/$file" 2>/dev/null || stat -c%s "$extract_path/$file" 2>/dev/null)
            log "    ✓ $file ($size bytes)"
        else
            warn "    ⚠ $file not found"
        fi
    done

    #STEP 6: Verify Flask application files
    log "  Verifying Flask application..."

    local app_files=("app.py" "config.py" "models.py" "utils.py")
    local app_count=0
    for file in "${app_files[@]}"; do
        if [ -f "$extract_path/$file" ]; then
            ((app_count++))
        fi
    done

    if [ "$app_count" -gt 0 ]; then
        log "    ✓ Flask files found: $app_count"
    else
        warn "    ⚠ No Flask application files found"
    fi

    #STEP 7: Verify templates
    if [ -d "$extract_path/templates" ]; then
        local template_count=$(find "$extract_path/templates" -name "*.html" | wc -l)
        log "    ✓ Templates directory ($template_count files)"
    else
        warn "    ⚠ Templates directory not found"
    fi

    #Cleanup
    rm -rf "$verify_dir"

    if [ "$verification_ok" = false ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ BACKUP VERIFICATION FAILED                 ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Backup is corrupted or incomplete."
        error "DO NOT use this backup for restoration!"
        return 1
    fi

    maintenance_log "✓ Backup verification passed"
    log ""
    log "✓ Backup is VALID and can be used for restoration"
    log "  File: $backup_file"
    log "  Size: $(du -h "$backup_file" | cut -f1)"

    return 0
}

# ============================================
# RESTORE BACKUP
# ============================================
restore_backup() {
    local backup_file="$1"

    if [ -z "$backup_file" ]; then
        log "Available backups:"
        ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || {
            error "No backups found in $BACKUP_DIR"
            return 1
        }
        return 0
    fi
    
    if [ ! -f "$backup_file" ]; then
        error "Backup not found: $backup_file"
        return 1
    fi
    
    warn "⚠️  This will restore the backup and restart services!"
    read -p "Continue? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && {
        log "Restore cancelled"
        return 0
    }
    
    log "Restoring from backup..."
    
    # Create temporary restore directory
    local restore_dir="/tmp/thin-server-restore-$$"
    mkdir -p "$restore_dir"
    
    log "  Extracting backup..."
    tar xzf "$backup_file" -C "$restore_dir"
    
    local backup_name=$(basename "$backup_file" .tar.gz)
    cd "$restore_dir/$backup_name"
    
    log "  Restoring configuration..."
    [ -f config.env ] && cp config.env "$THINSERVER_ROOT/"
    [ -f .versions ] && cp .versions "$THINSERVER_ROOT/"
    
    log "  Restoring database..."
    if [ -f clients.db ]; then
        systemctl stop thinclient-manager
        cp clients.db "$APP_DIR/db/"
        systemctl start thinclient-manager
    fi
    
    log "  Restoring Flask app..."
    [ -f app.py ] && cp app.py "$APP_DIR/"
    [ -d templates ] && cp -a templates "$APP_DIR/"
    
    log "  Restoring Nginx config..."
    [ -f nginx-thinclient ] && {
        cp nginx-thinclient /etc/nginx/sites-available/thinclient
        nginx -t && systemctl reload nginx
    }
    
    log "  Restoring systemd service..."
    [ -f thinclient-manager.service ] && {
        cp thinclient-manager.service /etc/systemd/system/
        systemctl daemon-reload
    }
    
    cd /
    rm -rf "$restore_dir"
    
    log "✓ Restore completed"
    log "  Restarting services..."
    
    systemctl restart thinclient-manager
    systemctl restart nginx
    
    log "✓ Services restarted"
}

# ============================================
# SYSTEM DIAGNOSTICS
# ============================================
run_diagnostics() {
    log "Running system diagnostics..."
    echo ""
    
    # Services
    log "Services Status:"
    for svc in nginx tftpd-hpa thinclient-manager; do
        check_service "$svc"
    done
    echo ""
    
    # Files
    log "Critical Files:"
    for file in "$WEB_ROOT/boot.ipxe" \
                "$WEB_ROOT/kernels/vmlinuz" \
                "$WEB_ROOT/initrds/initrd-minimal.img" \
                "$APP_DIR/app.py" \
                "$APP_DIR/db/clients.db"; do
        if [ -f "$file" ]; then
            local size=$(du -h "$file" | cut -f1)
            log "  ✓ $(basename $file) ($size)"
        else
            error "  ✗ $(basename $file) - MISSING!"
        fi
    done
    echo ""
    
    # Modules
    log "Installed Modules:"
    if [ -f "$THINSERVER_ROOT/.versions" ]; then
        while IFS='=' read -r module version; do
            log "  $module: v$version"
        done < "$THINSERVER_ROOT/.versions"
    else
        warn "  No version information found"
    fi
    echo ""
    
    # Database
    log "Database Statistics:"
    if [ -f "$APP_DIR/db/clients.db" ]; then
        local clients=$(sqlite3 "$APP_DIR/db/clients.db" "SELECT COUNT(*) FROM client;" 2>/dev/null || echo "0")
        local logs=$(sqlite3 "$APP_DIR/db/clients.db" "SELECT COUNT(*) FROM client_log;" 2>/dev/null || echo "0")
        local db_size=$(du -h "$APP_DIR/db/clients.db" | cut -f1)
        
        log "  Total clients: $clients"
        log "  Total logs: $logs"
        log "  Database size: $db_size"
    else
        error "  Database not found"
    fi
    echo ""
    
    # Disk space
    log "Disk Space:"
    df -h "$WEB_ROOT" "$APP_DIR" "$TFTP_ROOT" 2>/dev/null | tail -n +2 | while read line; do
        log "  $line"
    done
    echo ""
    
    # Network
    log "Network Configuration:"
    log "  Server IP: $SERVER_IP"
    log "  RDS Server: $RDS_SERVER"
    log "  NTP Server: $NTP_SERVER"
    
    # Test connectivity
    if ping -c 1 -W 2 "$RDS_SERVER" >/dev/null 2>&1; then
        log "  ✓ RDS server reachable"
    else
        warn "  ⚠ RDS server not reachable"
    fi
    echo ""
    
    # Logs
    log "Recent Errors:"
    local errors=$(grep -i "error\|critical\|failed" "$LOG_DIR/server.log" 2>/dev/null | tail -5)
    if [ -n "$errors" ]; then
        echo "$errors" | while read line; do
            warn "  $line"
        done
    else
        log "  No recent errors found"
    fi
    echo ""
}

# ============================================
# MANUAL CLEANUP (30 DAYS RETENTION)
# ============================================
manual_cleanup() {
    maintenance_log "Running manual cleanup (30 days retention)..."

    #Clean old logs (but logrotate should handle this)
    log "  Cleaning old unrotated logs..."

    local log_files_deleted=0
    log_files_deleted=$(find /var/log/thinclient -name "*.log" -type f -mtime +30 2>/dev/null | wc -l)
    find /var/log/thinclient -name "*.log" -type f -mtime +30 -delete 2>/dev/null || true
    log "    Deleted $log_files_deleted old log file(s)"

    #Clean database (30 days retention)
    if [ -f "$DB_DIR/clients.db" ]; then
        log "  Cleaning old database entries..."

        # Check integrity before cleanup
        local integrity=$(sqlite3 "$DB_DIR/clients.db" "PRAGMA integrity_check;" 2>&1)
        if [ "$integrity" != "ok" ]; then
            error "    ✗ Database integrity check FAILED, skipping cleanup"
            error "      $integrity"
            return 1
        fi

        local client_logs_before=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM client_log;" 2>/dev/null || echo "0")
        sqlite3 "$DB_DIR/clients.db" \
            "DELETE FROM client_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
        local client_logs_after=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM client_log;" 2>/dev/null || echo "0")
        local client_logs_deleted=$((client_logs_before - client_logs_after))
        log "    Deleted $client_logs_deleted client log entries"

        local audit_logs_before=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM audit_log;" 2>/dev/null || echo "0")
        sqlite3 "$DB_DIR/clients.db" \
            "DELETE FROM audit_log WHERE timestamp < datetime('now', '-30 days');" 2>/dev/null || true
        local audit_logs_after=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM audit_log;" 2>/dev/null || echo "0")
        local audit_logs_deleted=$((audit_logs_before - audit_logs_after))
        log "    Deleted $audit_logs_deleted audit log entries"

        # Vacuum to reclaim space
        local db_size_before=$(du -h "$DB_DIR/clients.db" | cut -f1)
        sqlite3 "$DB_DIR/clients.db" "VACUUM;" 2>/dev/null || true
        local db_size_after=$(du -h "$DB_DIR/clients.db" | cut -f1)
        log "    Database optimized: $db_size_before → $db_size_after"
    else
        warn "    ⚠ Database not found"
    fi

    #Clean temporary files
    log "  Cleaning temporary files..."

    local temp_dirs=("/tmp/freerdp-build*" "/tmp/initramfs-*" "/tmp/driver-*" "/tmp/thin-server-*")
    local temp_count=0

    for pattern in "${temp_dirs[@]}"; do
        local count=$(find /tmp -maxdepth 1 -name "$(basename "$pattern")" 2>/dev/null | wc -l)
        temp_count=$((temp_count + count))
        rm -rf /tmp/$(basename "$pattern") 2>/dev/null || true
    done

    log "    Removed $temp_count temporary directory/file(s)"

    maintenance_log "✓ Manual cleanup completed"
    maintenance_log "  Log files deleted: $log_files_deleted"
    maintenance_log "  Client logs deleted: $client_logs_deleted"
    maintenance_log "  Audit logs deleted: $audit_logs_deleted"
    maintenance_log "  Temp files removed: $temp_count"

    return 0
}

# ============================================
# UPDATE ALL MODULES
# ============================================
update_all_modules() {
    log "Checking for module updates..."

    local updates_available=false

    declare -A module_files=(
        ["core-system"]="01-core-system.sh"
        ["initramfs"]="02-initramfs.sh"
        ["web-panel"]="03-web-panel.sh"
        ["boot-config"]="04-boot-config.sh"
    )
    
    for module in core-system initramfs web-panel boot-config; do
        if needs_update "$module"; then
            warn "  Update available: $module"
            updates_available=true
        else
            log "  ✓ $module (up-to-date)"
        fi
    done
    
    if [ "$updates_available" = false ]; then
        log "✓ All modules are up-to-date"
        return 0
    fi
    
    read -p "Update all modules? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy] ]] && return 0
    
    log "Updating modules..."
    
    # Create backup first
    backup_system
    
    #ВИПРАВЛЕННЯ: Правильний шлях до модулів
    local modules_dir="$(dirname "$SCRIPT_DIR")/modules"
    
    # Update modules
    for module in core-system initramfs web-panel boot-config; do
        if needs_update "$module"; then
            local module_file="${module_files[$module]}"
            bash "$modules_dir/$module_file" || {
                error "Update failed for $module"
                return 1
            }
        fi
    done
    
    log "✓ All modules updated"
}

# ============================================
# SHOW USAGE
# ============================================
show_usage() {
    cat << EOF
Thin-Server Maintenance Module v$MODULE_VERSION - ENHANCED

Usage: $0 [command] [options]

Commands:
  setup          - Setup automatic maintenance (logrotate, db backup, cleanup)
  backup         - Create system backup with integrity validation
  verify <FILE>  - Verify backup integrity
  restore <FILE> - Restore from backup
  diagnostics    - Run comprehensive system diagnostics
  cleanup        - Manual cleanup (30 days retention)
  update         - Check and update all modules

Examples:
  $0 setup                                      # Initial setup (run during installation)
  $0 backup                                     # Create backup now
  $0 verify /opt/thin-server/backups/thin-server-...     # Verify backup integrity
  $0 restore /opt/thin-server/backups/thin-server-...    # Restore from backup
  $0 diagnostics                                # Check system health
  $0 cleanup                                    # Clean old files manually
  $0 update                                     # Update all modules

Features:
  - Logrotate configuration (30 days retention)
  - Database integrity checks before/after backup
  - Maintenance logs to /var/log/thinclient/maintenance.log
  - Automatic cleanup with vacuum and optimization
  - Comprehensive validation and error handling

Logs:
  All maintenance operations are logged to:
  - /var/log/thinclient/maintenance.log (visible in admin panel)
  - /var/log/thinclient/server.log (standard log)

EOF
}

# ============================================
# MAIN
# ============================================
main() {
    local command="${1:-}"

    case "$command" in
        setup)
            # Full setup during installation
            log ""
            if ! validate_maintenance_environment; then
                error "╔═══════════════════════════════════════════════╗"
                error "║  ✗ MAINTENANCE ENVIRONMENT VALIDATION FAILED  ║"
                error "╚═══════════════════════════════════════════════╝"
                exit 1
            fi

            log ""
            maintenance_log "═══════════════════════════════════════"
            maintenance_log "Setting up Maintenance System..."
            maintenance_log "═══════════════════════════════════════"

            if ! setup_logrotate; then
                error "✗ Logrotate setup failed"
                exit 1
            fi

            log ""
            if ! setup_db_backup; then
                error "✗ Database backup setup failed"
                exit 1
            fi

            log ""
            if ! setup_database_cleanup; then
                error "✗ Database cleanup setup failed"
                exit 1
            fi

            log ""
            maintenance_log "╔═══════════════════════════════════════════════╗"
            maintenance_log "║  ✓ MAINTENANCE SYSTEM CONFIGURED              ║"
            maintenance_log "╚═══════════════════════════════════════════════╝"
            maintenance_log ""
            maintenance_log "Automatic tasks configured:"
            maintenance_log "  - Log rotation: Daily (30 days retention)"
            maintenance_log "  - Database backup: Daily at 2:00 AM"
            maintenance_log "  - Database cleanup: Daily"
            maintenance_log ""
            maintenance_log "Logs available at:"
            maintenance_log "  /var/log/thinclient/maintenance.log"

            # Register module version
            register_module "$MODULE_NAME" "$MODULE_VERSION"
            ;;

        backup)
            maintenance_log "Manual backup requested"
            if ! backup_system; then
                error "✗ Backup failed"
                exit 1
            fi
            ;;

        verify)
            local backup_file="${2:-}"
            if [ -z "$backup_file" ]; then
                error "Usage: $0 verify <backup-file>"
                log ""
                log "Available backups:"
                ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || log "  No backups found"
                exit 1
            fi

            verify_backup "$backup_file"
            ;;

        restore)
            restore_backup "${2:-}"
            ;;

        diagnostics|status|check)
            run_diagnostics
            ;;

        cleanup|clean)
            manual_cleanup
            ;;

        update)
            update_all_modules
            ;;

        help|--help|-h)
            show_usage
            ;;

        "")
            # If called without arguments during installation
            if [ -t 0 ]; then
                show_usage
            else
                # Non-interactive installation - run setup
                log ""
                if ! validate_maintenance_environment; then
                    error "✗ Maintenance environment validation failed"
                    exit 1
                fi

                log ""
                setup_logrotate || exit 1
                log ""
                setup_db_backup || exit 1
                log ""
                setup_database_cleanup || exit 1

                log ""
                maintenance_log "✓ Maintenance module v$MODULE_VERSION installed"

                # Register module version
                register_module "$MODULE_NAME" "$MODULE_VERSION"
            fi
            ;;

        *)
            error "Unknown command: $command"
            log ""
            show_usage
            exit 1
            ;;
    esac
}

main "$@"