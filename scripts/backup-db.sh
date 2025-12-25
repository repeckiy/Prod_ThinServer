#!/usr/bin/env bash
# Thin-Server Database Backup Script
# Автоматичний backup SQLite БД з ротацією

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THINSERVER_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions if available, otherwise define minimal functions
if [ -f "$THINSERVER_ROOT/common.sh" ]; then
    source "$THINSERVER_ROOT/common.sh"
else
    # Fallback minimal logging for standalone execution
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'

    log() {
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${GREEN}[$timestamp]${NC} $*"
    }

    error() {
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${RED}[$timestamp] ERROR:${NC} $*"
    }

    warn() {
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${YELLOW}[$timestamp] WARN:${NC} $*"
    }
fi

# ============================================
# CONFIGURATION
# ============================================
DB_PATH="${DB_PATH:-/opt/thinclient-manager/db/clients.db}"
BACKUP_DIR="${BACKUP_DIR:-/opt/thin-server/backups/db}"
RETENTION_DAYS="${RETENTION_DAYS:-2}"
LOG_FILE="${LOG_FILE:-/var/log/thinclient/db-backup.log}"

# ============================================
# BACKUP FUNCTION
# ============================================
backup_database() {
    log "Starting database backup..."
    
    # Check if database exists
    if [ ! -f "$DB_PATH" ]; then
        error "Database not found: $DB_PATH"
        return 1
    fi
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Generate backup filename with timestamp
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="$BACKUP_DIR/clients-$timestamp.db"
    local compressed_file="$backup_file.gz"
    
    # Get database size
    local db_size=$(du -h "$DB_PATH" | cut -f1)
    log "Database size: $db_size"
    
    # Backup database using SQLite's .backup command (safest method)
    if command -v sqlite3 >/dev/null 2>&1; then
        log "Creating backup: $(basename "$backup_file")"
        
        if sqlite3 "$DB_PATH" ".backup '$backup_file'"; then
            log "✓ Backup created successfully"
        else
            error "Failed to create backup"
            return 1
        fi
    else
        error "sqlite3 command not found!"
        return 1
    fi
    
    # Compress backup
    log "Compressing backup..."
    if gzip "$backup_file"; then
        local compressed_size=$(du -h "$compressed_file" | cut -f1)
        log "✓ Backup compressed: $compressed_size"
    else
        error "Failed to compress backup"
        return 1
    fi
    
    # Verify backup integrity
    log "Verifying backup integrity..."
    if gunzip -t "$compressed_file" 2>/dev/null; then
        log "✓ Backup integrity verified"
    else
        error "Backup integrity check failed!"
        return 1
    fi
    
    log "✓ Backup completed: $compressed_file"
    
    return 0
}

# ============================================
# CLEANUP OLD BACKUPS
# ============================================
cleanup_old_backups() {
    log "Cleaning up old backups (retention: ${RETENTION_DAYS} days)..."
    
    if [ ! -d "$BACKUP_DIR" ]; then
        warn "Backup directory does not exist: $BACKUP_DIR"
        return 0
    fi
    
    # Count total backups before cleanup
    local total_before=$(find "$BACKUP_DIR" -name "clients-*.db.gz" 2>/dev/null | wc -l)
    
    # Delete backups older than retention period
    local deleted=0
    while IFS= read -r old_backup; do
        log "  Deleting old backup: $(basename "$old_backup")"
        rm -f "$old_backup"
        ((deleted++))
    done < <(find "$BACKUP_DIR" -name "clients-*.db.gz" -mtime +${RETENTION_DAYS} 2>/dev/null)
    
    local total_after=$(find "$BACKUP_DIR" -name "clients-*.db.gz" 2>/dev/null | wc -l)
    
    log "✓ Cleanup completed: $deleted old backup(s) deleted"
    log "  Backups: $total_before → $total_after"
    
    # Show current backups
    if [ "$total_after" -gt 0 ]; then
        log "Current backups:"
        find "$BACKUP_DIR" -name "clients-*.db.gz" -printf "  %TY-%Tm-%Td %TH:%TM  %10s  %f\n" | sort -r | head -10
    fi
    
    return 0
}

# ============================================
# LIST BACKUPS
# ============================================
list_backups() {
    log "Available backups:"
    
    if [ ! -d "$BACKUP_DIR" ]; then
        warn "Backup directory does not exist: $BACKUP_DIR"
        return 0
    fi
    
    local count=0
    while IFS= read -r backup; do
        local size=$(du -h "$backup" | cut -f1)
        local date=$(stat -c "%y" "$backup" | cut -d' ' -f1,2 | cut -d'.' -f1)
        printf "  %-35s  %8s  %s\n" "$(basename "$backup")" "$size" "$date"
        ((count++))
    done < <(find "$BACKUP_DIR" -name "clients-*.db.gz" | sort -r)
    
    if [ "$count" -eq 0 ]; then
        warn "No backups found"
    else
        log "Total backups: $count"
    fi
    
    return 0
}

# ============================================
# RESTORE BACKUP
# ============================================
restore_backup() {
    local backup_file="$1"
    
    if [ -z "$backup_file" ]; then
        error "Usage: $0 restore <backup-file.gz>"
        return 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        error "Backup file not found: $backup_file"
        return 1
    fi
    
    log "Restoring backup: $backup_file"
    
    # Create backup of current database
    if [ -f "$DB_PATH" ]; then
        local current_backup="$DB_PATH.before-restore-$(date +%Y%m%d-%H%M%S)"
        log "Creating backup of current database: $current_backup"
        cp "$DB_PATH" "$current_backup"
    fi
    
    # Decompress and restore
    log "Decompressing backup..."
    local temp_db="/tmp/clients-restore-$$.db"
    
    if gunzip -c "$backup_file" > "$temp_db"; then
        log "✓ Backup decompressed"
    else
        error "Failed to decompress backup"
        return 1
    fi
    
    # Verify decompressed database
    if sqlite3 "$temp_db" "PRAGMA integrity_check;" | grep -q "ok"; then
        log "✓ Database integrity verified"
    else
        error "Database integrity check failed!"
        rm -f "$temp_db"
        return 1
    fi
    
    # Stop Flask service
    log "Stopping thinclient-manager service..."
    systemctl stop thinclient-manager 2>/dev/null || true
    sleep 2
    
    # Replace database
    log "Replacing database..."
    mv "$temp_db" "$DB_PATH"
    chown www-data:www-data "$DB_PATH" 2>/dev/null || true
    chmod 644 "$DB_PATH"
    
    # Start Flask service
    log "Starting thinclient-manager service..."
    systemctl start thinclient-manager
    
    log "✓ Database restored successfully"
    log "  Previous database backed up to: $current_backup"
    
    return 0
}

# ============================================
# MAIN
# ============================================
main() {
    local command="${1:-backup}"
    
    case "$command" in
        backup)
            backup_database && cleanup_old_backups
            ;;
        list)
            list_backups
            ;;
        restore)
            restore_backup "$2"
            ;;
        cleanup)
            cleanup_old_backups
            ;;
        help|--help|-h)
            cat << EOF
Thin-Server Database Backup Tool

Usage: $0 <command> [options]

Commands:
    backup      Create new backup and cleanup old backups (default)
    list        List available backups
    restore     Restore backup from file
    cleanup     Remove old backups
    help        Show this help

Examples:
    $0 backup
    $0 list
    $0 restore /opt/thin-server/backups/db/clients-20241018-120000.db.gz
    $0 cleanup

Configuration:
    DB_PATH=$DB_PATH
    BACKUP_DIR=$BACKUP_DIR
    RETENTION_DAYS=$RETENTION_DAYS
    LOG_FILE=$LOG_FILE

Cron Setup:
    # Add to /etc/cron.d/thin-server-backup:
    0 2 * * * root $0 backup

EOF
            ;;
        *)
            error "Unknown command: $command"
            echo "Run '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

main "$@"