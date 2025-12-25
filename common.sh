#!/usr/bin/env bash
# Thin-Server Common Functions

set -euo pipefail

# ============================================
# CONFIGURATION
# ============================================
COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get application version from config.py (single source of truth)
get_app_version() {
    local config_file="$COMMON_SCRIPT_DIR/config.py"
    if [ -f "$config_file" ]; then
        grep "VERSION = " "$config_file" | head -1 | cut -d"'" -f2
    else
        echo "7.8.0"  # Fallback
    fi
}

# ============================================
# VERSION MANAGEMENT
# ============================================
APP_VERSION=$(get_app_version)

declare -gA MODULE_VERSIONS 2>/dev/null || declare -A MODULE_VERSIONS
MODULE_VERSIONS=(
    ["core-system"]="$APP_VERSION"
    ["initramfs"]="$APP_VERSION"
    ["web-panel"]="$APP_VERSION"
    ["boot-config"]="$APP_VERSION"
    ["maintenance"]="$APP_VERSION"
)

# ============================================
# COLOR CODES (exported for use in all scripts)
# ============================================
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# ============================================
# APT UPDATE TRACKING
# ============================================
export APT_UPDATED="${APT_UPDATED:-0}"

# ============================================
# CONFIG.ENV LOADING
# ============================================
if [ -f "$COMMON_SCRIPT_DIR/config.env" ]; then
    CONFIG_FILE="$COMMON_SCRIPT_DIR/config.env"
elif [ -f "$COMMON_SCRIPT_DIR/../config.env" ]; then
    CONFIG_FILE="$COMMON_SCRIPT_DIR/../config.env"
elif [ -f "/opt/thin-server/config.env" ]; then
    CONFIG_FILE="/opt/thin-server/config.env"
else
    echo -e "${RED}[ERROR]${NC} config.env not found!"
    echo "Searched in:"
    echo "  - $COMMON_SCRIPT_DIR/config.env"
    echo "  - $COMMON_SCRIPT_DIR/../config.env"
    echo "  - /opt/thin-server/config.env"
    exit 1
fi

# Load configuration (use set -a to auto-export all variables)
set -a
source "$CONFIG_FILE"
set +a

# Set default values if not in config
: "${SERVER_IP:=127.0.0.1}"
: "${RDS_SERVER:=rds.example.com}"
: "${NTP_SERVER:=pool.ntp.org}"
: "${WEB_ROOT:=/var/www/thinclient}"
: "${TFTP_ROOT:=/srv/tftp}"
: "${APP_DIR:=/opt/thinclient-manager}"
: "${DB_DIR:=$APP_DIR/db}"
: "${LOG_DIR:=/var/log/thinclient}"
: "${BACKUP_DIR:=/opt/thin-server/backups}"
: "${THINSERVER_ROOT:=/opt/thin-server}"
: "${VERSIONS_FILE:=/opt/thin-server/.versions}"

# ============================================
# LOGGING
# ============================================
# Ensure log directory exists FIRST
mkdir -p "$LOG_DIR"

LOG_FILE="${LOG_DIR}/thin-server-install-$(date +%Y%m%d-%H%M%S).log"

log() {
    local timestamp=$(date '+%H:%M:%S')
    echo -e "${GREEN}[${timestamp}]${NC} $*" | tee -a "$LOG_FILE"
}

warn() {
    local timestamp=$(date '+%H:%M:%S')
    echo -e "${YELLOW}[${timestamp}] ⚠${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    local timestamp=$(date '+%H:%M:%S')
    echo -e "${RED}[${timestamp}] ✗${NC} $*" | tee -a "$LOG_FILE"
}

section() {
    echo "" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════" | tee -a "$LOG_FILE"
    echo "  $*" | tee -a "$LOG_FILE"
    echo "═══════════════════════════════════════" | tee -a "$LOG_FILE"
}

# ============================================
# UTILITY FUNCTIONS
# ============================================
ensure_dir() {
    local dir="$1"
    local perms="${2:-755}"
    
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chmod "$perms" "$dir"
    fi
}

backup_file() {
    local file="$1"
    
    if [ -f "$file" ]; then
        cp "$file" "${file}.backup-$(date +%Y%m%d-%H%M%S)"
    fi
}

restart_service() {
    local service="$1"
    
    if systemctl is-active --quiet "$service"; then
        systemctl restart "$service"
        log "  ✓ $service restarted"
    else
        systemctl start "$service"
        log "  ✓ $service started"
    fi
}

check_service() {
    local service="$1"
    
    if systemctl is-active --quiet "$service"; then
        log "  ✓ $service is running"
        return 0
    else
        error "  ✗ $service is not running"
        return 1
    fi
}

run_apt_update() {
    # Run apt-get update only once per session
    # Uses APT_UPDATED flag to track if already executed

    if [ "${APT_UPDATED:-0}" = "1" ]; then
        log "  ↻ APT cache already updated (skipping)"
        return 0
    fi

    log "Updating APT cache..."

    if apt-get update -qq 2>&1 | tee -a "$LOG_FILE"; then
        export APT_UPDATED=1
        log "  ✓ APT cache updated"
        return 0
    else
        error "Failed to update APT cache"
        return 1
    fi
}

# ============================================
# MODULE MANAGEMENT - COMPLETE
# ============================================
register_module() {
    local module_name="$1"
    local provided_version="${2:-}"
    # Use provided version if given, otherwise lookup in MODULE_VERSIONS, fallback to 7.6.3
    local module_version="${provided_version:-${MODULE_VERSIONS[$module_name]:-7.6.3}}"
    local versions_file="${VERSIONS_FILE:-/opt/thin-server/.versions}"
    
    ensure_dir "$(dirname "$versions_file")"
    
    # Update or add module version
    if [ -f "$versions_file" ]; then
        if grep -q "^${module_name}=" "$versions_file" 2>/dev/null; then
            sed -i "s/^${module_name}=.*/${module_name}=${module_version}/" "$versions_file"
        else
            echo "${module_name}=${module_version}" >> "$versions_file"
        fi
    else
        echo "${module_name}=${module_version}" > "$versions_file"
    fi
    
    log "  ✓ Module $module_name v${module_version} registered"
}

# Get installed version of a module
get_installed_version() {
    local module_name="$1"
    local versions_file="${VERSIONS_FILE:-/opt/thin-server/.versions}"
    
    if [ ! -f "$versions_file" ]; then
        echo "0.0.0"
        return
    fi
    
    if grep -q "^${module_name}=" "$versions_file" 2>/dev/null; then
        grep "^${module_name}=" "$versions_file" | cut -d'=' -f2
    else
        echo "0.0.0"
    fi
}

check_module_installed() {
    local module_name="$1"
    local versions_file="${VERSIONS_FILE:-/opt/thin-server/.versions}"
    
    if [ ! -f "$versions_file" ]; then
        return 1
    fi
    
    if grep -q "^${module_name}=" "$versions_file" 2>/dev/null; then
        local installed_version=$(grep "^${module_name}=" "$versions_file" | cut -d'=' -f2)
        log "  ✓ Dependency satisfied: $module_name v${installed_version}"
        return 0
    fi
    
    return 1
}

verify_module_installed() {
    # Verify module is installed AND working (checks actual artifacts)
    # Returns 0 if module is installed and functional, 1 otherwise

    local module_name="$1"

    # First check registration
    if ! check_module_installed "$module_name"; then
        error "Module $module_name not registered"
        return 1
    fi

    # Check actual artifacts based on module type
    case "$module_name" in
        "core-system")
            if [ ! -f "/usr/local/bin/xfreerdp" ]; then
                error "FreeRDP binary not found"
                return 1
            fi
            log "  ✓ core-system artifacts verified"
            ;;

        "initramfs")
            if [ ! -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
                error "Initramfs not found at $WEB_ROOT/initrds/initrd-minimal.img"
                return 1
            fi
            log "  ✓ initramfs artifacts verified"
            ;;

        "web-panel")
            if [ ! -f "$APP_DIR/app.py" ]; then
                error "Flask app not found at $APP_DIR/app.py"
                return 1
            fi
            if ! systemctl is-active --quiet thinclient-manager; then
                error "Flask service not running"
                return 1
            fi
            log "  ✓ web-panel artifacts verified"
            ;;

        "boot-config")
            if [ ! -f "$WEB_ROOT/boot.ipxe" ]; then
                error "boot.ipxe not found"
                return 1
            fi
            if [ ! -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
                error "iPXE bootloader not found"
                return 1
            fi
            log "  ✓ boot-config artifacts verified"
            ;;

        *)
            # For other modules, just check registration
            log "  ✓ $module_name registered (no artifact checks)"
            ;;
    esac

    return 0
}

needs_update() {
    local module_name="$1"
    local current_version=$(get_module_version "$module_name")
    local new_version="${MODULE_VERSIONS[$module_name]:-7.6.3}"
    
    if [ "$current_version" = "not-installed" ]; then
        return 0  # Needs installation
    fi
    
    if [ "$current_version" != "$new_version" ]; then
        return 0  # Needs update
    fi
    
    return 1  # Up to date
}

# ============================================
# SYSTEM CHECKS
# ============================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root (sudo)"
        exit 1
    fi
}

check_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release

        case "$ID" in
            debian|ubuntu)
                log "  ✓ OS: $PRETTY_NAME"
                return 0
                ;;
            *)
                warn "Unsupported OS: $PRETTY_NAME"
                warn "Script designed for Debian/Ubuntu"
                read -p "Continue anyway? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
                ;;
        esac
    else
        error "Cannot detect OS"
        exit 1
    fi
}

# ============================================
# APT SOURCES FIX (shared function)
# ============================================
fix_apt_sources() {
    log "Checking APT sources..."

    # Remove cdrom entries
    if grep -q "cdrom:" /etc/apt/sources.list 2>/dev/null; then
        log "  Removing cdrom from sources.list..."
        sed -i '/cdrom:/d' /etc/apt/sources.list
    fi

    # Ensure Debian repos are present
    if ! grep -q "deb.debian.org" /etc/apt/sources.list; then
        log "  Fixing APT sources..."
        cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF
        log "  ✓ APT sources fixed"
        run_apt_update
    else
        log "  ✓ APT sources OK"
    fi
}

check_disk_space() {
    local required_mb=5000  # 5GB
    local available_mb=$(df -m / | tail -1 | awk '{print $4}')
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        error "Insufficient disk space"
        error "Required: ${required_mb}MB, Available: ${available_mb}MB"
        exit 1
    fi
    
    log "  ✓ Disk space: ${available_mb}MB available"
}

check_network() {
    if ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        warn "No internet connection"
        warn "Installation may fail if packages need to be downloaded"
        read -p "Continue anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    else
        log "  ✓ Network: OK"
    fi
}

# ============================================
# SYSTEM TIME STABILIZATION
# ============================================
wait_for_time_sync() {
    local max_wait=30
    local wait_count=0
    
    log "Waiting for time synchronization..."
    
    while [ $wait_count -lt $max_wait ]; do
        # Check if timedatectl shows system clock synchronized
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            log "  ✓ System time synchronized"
            return 0
        fi
        
        # Check if we at least have a reasonable date (after 2020)
        local current_year=$(date +%Y)
        if [ "$current_year" -ge 2020 ]; then
            log "  ✓ System time appears reasonable"
            return 0
        fi
        
        sleep 1
        ((wait_count++))
    done
    
    warn "Time sync timeout, but continuing..."
    return 0
}

force_time_update() {
    # Skip if already synced by deploy.sh
    if [ -f /tmp/thin-server-time-synced ] || [ "$TIME_SYNC_DONE" = "1" ]; then
        log "  ↻ Time already synchronized, skipping"
        return 0
    fi

    log "Forcing time update..."

    # Try to sync time immediately
    if command -v ntpdate >/dev/null 2>&1; then
        ntpdate -u "$NTP_SERVER" 2>/dev/null || true
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
        # Force sync
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi

    wait_for_time_sync

    local current_time=$(date)
    log "  ✓ Current time: $current_time"
}

# ============================================
# APT FIX FUNCTIONS
# ============================================
fix_apt_time_issues() {
    log "Fixing APT time-related issues..."
    
    # Option 1: Temporarily disable time validation
    cat > /etc/apt/apt.conf.d/99-no-check-valid-until << 'EOF'
Acquire::Check-Valid-Until "false";
EOF
    
    log "  ✓ Disabled APT time validation temporarily"
    
    # Option 2: Force time sync
    force_time_update
    
    # Option 3: Try apt update again
    if apt-get update -qq 2>&1 | tee -a "$LOG_FILE"; then
        log "  ✓ APT update successful"
        # Remove temporary config
        rm -f /etc/apt/apt.conf.d/99-no-check-valid-until
        return 0
    else
        warn "  APT update still has issues, continuing..."
        return 1
    fi
}

# ============================================
# INITIALIZATION
# ============================================
log "Thin-Server v$APP_VERSION - Common functions loaded"
log "Log file: $LOG_FILE"