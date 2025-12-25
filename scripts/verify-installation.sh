#!/bin/bash
#
# Thin-Server Installation Verification Script
# Перевіряє коректність установки та конфігурації системи
#
# Usage:
#   verify-installation.sh          # Pre-deployment checks
#   verify-installation.sh --pre    # Pre-deployment checks
#   verify-installation.sh --post   # Post-deployment checks

set +e  # Continue on errors - we want to see all issues

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

# Check mode
MODE="${1:---pre}"

if [ "$MODE" = "--post" ]; then
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  Thin-Server Post-Install Verification ║"
    echo "╚═══════════════════════════════════════════════╝"
else
    echo "╔═══════════════════════════════════════════════╗"
    echo "║  Thin-Server Pre-Install Verification  ║"
    echo "╚═══════════════════════════════════════════════╝"
fi
echo ""

# Helper functions
pass() {
    echo -e "${GREEN}✓${NC} $1"
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((ERRORS++))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    ((WARNINGS++))
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

#Progress spinner for long operations
show_progress() {
    local message="$1"
    local pid=$2
    local delay=0.1
    local spinstr='|/-\'
    echo -n "$message "
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b"
    done
    printf "   \b\b\b"
    echo ""
}

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
if [ -f "$SCRIPT_DIR/../config.env" ]; then
    source "$SCRIPT_DIR/../config.env"
elif [ -f "/opt/thin-server/config.env" ]; then
    source "/opt/thin-server/config.env"
fi
set +a

# Set defaults if not loaded
WEB_ROOT="${WEB_ROOT:-/var/www/thinclient}"
TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"

check_file() {
    local file="$1"
    local description="$2"

    if [ -f "$file" ]; then
        pass "$description: $file"
        return 0
    else
        fail "$description: $file NOT FOUND"
        return 1
    fi
}

# ============================================
# 1. FILE EXISTENCE
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Checking File Existence"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# Core Python files
check_file "app.py" "Main application"
check_file "models.py" "Database models"
check_file "config.py" "Configuration"
check_file "utils.py" "Utilities"
check_file "cli.py" "CLI tool"

# Deployment scripts
check_file "deploy.sh" "Deployment script"
check_file "install.sh" "Installation script"
check_file "common.sh" "Common functions"

# Modules
check_file "modules/01-core-system.sh" "Core system module"
check_file "modules/02-initramfs.sh" "Initramfs module"
check_file "modules/03-web-panel.sh" "Web panel module"
check_file "modules/04-boot-config.sh" "Boot config module"
check_file "modules/05-maintenance.sh" "Maintenance module"

# Scripts
check_file "scripts/backup-db.sh" "Database backup script"
check_file "scripts/verify-installation.sh" "Verification script"

# API files
check_file "api/__init__.py" "API init"
check_file "api/boot.py" "Boot API"
check_file "api/logs.py" "Logs API"
check_file "api/clients.py" "Clients API"
check_file "api/admins.py" "Admins API"
check_file "api/auth.py" "Auth API"
check_file "api/system.py" "System API"

# Templates
check_file "templates/index.html" "Main template"
check_file "templates/base.html" "Base template"
check_file "templates/login.html" "Login template"

# Configuration
check_file "config.env" "Configuration file"
check_file "requirements.txt" "Python requirements"

echo ""

# ============================================
# 2. PYTHON SYNTAX
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. Checking Python Syntax"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for pyfile in app.py models.py config.py utils.py cli.py api/*.py; do
    if python3 -m py_compile "$pyfile" 2>/dev/null; then
        pass "Syntax OK: $pyfile"
    else
        fail "Syntax ERROR: $pyfile"
    fi
done

echo ""

# ============================================
# 3. BASH SYNTAX
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. Checking Bash Syntax"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for bashfile in deploy.sh install.sh common.sh modules/*.sh scripts/*.sh; do
    [ ! -f "$bashfile" ] && continue
    if bash -n "$bashfile" 2>/dev/null; then
        pass "Syntax OK: $bashfile"
    else
        fail "Syntax ERROR: $bashfile"
    fi
done

echo ""

# ============================================
# 4. CRITICAL FIXES VERIFICATION
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. Verifying Critical Fixes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 4.1 PBKDF2HMAC import (not PBKDF2)
if grep -q "from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC" models.py; then
    pass "PBKDF2HMAC import correct"
else
    fail "PBKDF2HMAC import WRONG (should be PBKDF2HMAC not PBKDF2)"
fi

# 4.2 Password encryption functions
if grep -q "def encrypt_password" models.py && grep -q "def decrypt_password" models.py; then
    pass "Password encryption functions present"
else
    fail "Password encryption functions MISSING"
fi

# 4.3 Boot token methods
if grep -q "def generate_boot_token" models.py && grep -q "def validate_boot_token" models.py; then
    pass "Boot token methods present"
else
    fail "Boot token methods MISSING"
fi

# 4.4 SECRET_KEY generation
if grep -q "_get_or_generate_secret_key" config.py; then
    pass "SECRET_KEY auto-generation present"
else
    fail "SECRET_KEY auto-generation MISSING"
fi

# 4.5 Input validation functions
if grep -q "def validate_mac" utils.py && \
   grep -q "def validate_hostname" utils.py && \
   grep -q "def validate_client_params" utils.py; then
    pass "Input validation functions present"
else
    fail "Input validation functions MISSING or INCOMPLETE"
fi

# 4.6 Input device wait in initramfs
if grep -q "WAIT FOR INPUT DEVICES" modules/02-initramfs.sh && \
   grep -q "udevadm trigger --subsystem-match=input" modules/02-initramfs.sh; then
    pass "Input device wait logic present"
else
    fail "Input device wait logic MISSING"
fi

# 4.7 Input kernel modules (evdev + libinput)
if grep -q "modprobe evdev" modules/02-initramfs.sh && \
   grep -q "libinput_drv.so" modules/02-initramfs.sh; then
    pass "Input kernel modules present (evdev + libinput)"
else
    fail "Input kernel modules MISSING (evdev or libinput)"
fi

# 4.8 RDP SSL bypass
if grep -q "/cert:ignore" modules/02-initramfs.sh; then
    pass "RDP SSL bypass options present (/cert:ignore)"
else
    fail "RDP SSL bypass options MISSING"
fi

# 4.9 RDP retry counter
if grep -q "MAX_RDP_RETRIES=10" modules/02-initramfs.sh; then
    pass "RDP retry counter present (max 10)"
else
    fail "RDP retry counter MISSING (should be MAX_RDP_RETRIES=10)"
fi

# 4.10 Time sync marker
if grep -q "TIME_SYNC_DONE" deploy.sh && \
   grep -q "/tmp/thin-server-time-synced" deploy.sh; then
    pass "Time sync optimization present"
else
    fail "Time sync optimization MISSING"
fi

# 4.11 Log message size limits
if grep -q "MAX_LOG_MESSAGE_SIZE" api/logs.py; then
    pass "Log message size limits present"
else
    fail "Log message size limits MISSING"
fi

# 4.12 JavaScript duplicate fix
DUPLICATE_COUNT=$(grep -c "let currentClientId" templates/index.html 2>/dev/null || echo 0)
if [ "$DUPLICATE_COUNT" -eq 1 ]; then
    pass "JavaScript duplicate variable fixed (only 1 declaration)"
elif [ "$DUPLICATE_COUNT" -gt 1 ]; then
    fail "JavaScript duplicate variable NOT FIXED ($DUPLICATE_COUNT declarations)"
else
    fail "JavaScript currentClientId variable NOT FOUND"
fi

# 4.13 JavaScript safe rendering
if grep -q "String(log.category || 'other')" templates/index.html && \
   grep -q "category ? category.toUpperCase() : 'OTHER'" templates/index.html; then
    pass "JavaScript safe rendering present"
else
    fail "JavaScript safe rendering MISSING"
fi

# 4.14 Database auto-init
if grep -q "if not init_database(app):" app.py; then
    pass "Database auto-initialization present"
else
    fail "Database auto-initialization MISSING"
fi

# 4.15 Boot credentials endpoint
if grep -q "/boot/credentials/<token>" api/boot.py; then
    pass "Boot credentials endpoint present"
else
    fail "Boot credentials endpoint MISSING"
fi

# 4.16 CLI tool utility functions
if grep -q "def get_system_stats" utils.py; then
    pass "get_system_stats function present (for cli.py)"
else
    warn "get_system_stats function MISSING (cli.py may fail)"
fi

# 4.17 Backup script functionality
if grep -q "backup_database()" scripts/backup-db.sh && \
   grep -q "RETENTION_DAYS=" scripts/backup-db.sh; then
    pass "Database backup script configured"
else
    warn "Database backup script may be incomplete"
fi

# 4.18 Maintenance cron setup
if grep -q "setup_db_backup" modules/05-maintenance.sh && \
   grep -q "/etc/cron.d/thin-server-db-backup" modules/05-maintenance.sh; then
    pass "Automatic database backup setup present"
else
    warn "Automatic database backup setup MISSING"
fi

# 4.19 Verify installation script integration
if grep -q "verify-installation.sh" deploy.sh; then
    pass "Pre-deployment verification integrated in deploy.sh"
else
    warn "Pre-deployment verification not integrated"
fi

echo ""

# ============================================
# 5. PYTHON DEPENDENCIES
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. Checking Python Dependencies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

#In PRE mode, missing Python deps are expected (will be installed)
# Don't count them as warnings, just show info

if python3 -c "from cryptography.fernet import Fernet; from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC" 2>/dev/null; then
    pass "cryptography library OK"
else
    if [ "$MODE" = "--pre" ]; then
        info "cryptography library will be installed via requirements.txt"
    else
        warn "cryptography library MISSING (will be installed via requirements.txt)"
    fi
fi

if python3 -c "import flask, flask_sqlalchemy" 2>/dev/null; then
    pass "Flask and Flask-SQLAlchemy OK"
else
    if [ "$MODE" = "--pre" ]; then
        info "Flask/Flask-SQLAlchemy will be installed via requirements.txt"
    else
        warn "Flask/Flask-SQLAlchemy MISSING (will be installed via requirements.txt)"
    fi
fi

if python3 -c "import pytz" 2>/dev/null; then
    pass "pytz (timezone) OK"
else
    if [ "$MODE" = "--pre" ]; then
        info "pytz will be installed via requirements.txt"
    else
        warn "pytz MISSING (will be installed via requirements.txt)"
    fi
fi

if python3 -c "import click" 2>/dev/null; then
    pass "click (CLI framework) OK"
else
    if [ "$MODE" = "--pre" ]; then
        info "click will be installed via requirements.txt"
    else
        warn "click MISSING (needed for cli.py)"
    fi
fi

echo ""

# ============================================
# 6. CONFIGURATION VALIDATION
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. Validating Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "config.env" ]; then
    pass "config.env exists"

    # Check critical variables
    if grep -q "^SERVER_IP=" config.env; then
        pass "SERVER_IP configured"
    else
        warn "SERVER_IP not set in config.env"
    fi

    if grep -q "^RDS_SERVER=" config.env; then
        pass "RDS_SERVER configured"
    else
        warn "RDS_SERVER not set in config.env"
    fi

    if grep -q "^NTP_SERVER=" config.env; then
        pass "NTP_SERVER configured"
    else
        warn "NTP_SERVER not set in config.env"
    fi
else
    fail "config.env NOT FOUND"
fi

echo ""

# ============================================
# 7. DOCUMENTATION
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "7. Checking Documentation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check_file "README.md" "Main documentation" || warn "README.md missing"
check_file "requirements.txt" "Python requirements" || warn "requirements.txt missing"

echo ""

# ============================================
# POST-INSTALL CHECKS (only when --post)
# ============================================
if [ "$MODE" = "--post" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Module 01 - Core System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check FreeRDP
    info "Checking FreeRDP installation..."
    if [ -f "/usr/local/bin/xfreerdp" ]; then
        if [ -x "/usr/local/bin/xfreerdp" ]; then
            freerdp_version=$(/usr/local/bin/xfreerdp --version 2>&1 | grep -oP 'version \K[0-9.]+' | head -1 || echo "unknown")
            if [[ "$freerdp_version" == 3.* ]]; then
                pass "FreeRDP v$freerdp_version (correct version)"
            else
                warn "FreeRDP version $freerdp_version (expected 3.x)"
            fi
        else
            fail "FreeRDP not executable"
        fi
    else
        fail "FreeRDP NOT FOUND at /usr/local/bin/xfreerdp"
    fi

    # Check critical directories
    info "Checking directories..."

    # Load TFTP_ROOT from config.env (try multiple locations)
    if [ -z "$TFTP_ROOT" ]; then
        for config_path in "$SCRIPT_DIR/config.env" "/opt/thin-server/config.env" "$SCRIPT_DIR/../config.env"; do
            if [ -f "$config_path" ]; then
                TFTP_ROOT=$(grep "^TFTP_ROOT=" "$config_path" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
                [ -n "$TFTP_ROOT" ] && break
            fi
        done
        # Default if not found
        [ -z "$TFTP_ROOT" ] && TFTP_ROOT="/srv/tftp"
    fi

    dirs_ok=0
    dirs_total=4
    for dir in "$TFTP_ROOT" "/var/www/thinclient" "/opt/thinclient-manager" "/var/log/thinclient"; do
        if [ -d "$dir" ]; then
            ((dirs_ok++))
        else
            fail "Directory missing: $dir"
        fi
    done
    if [ $dirs_ok -eq $dirs_total ]; then
        pass "All $dirs_total directories exist"
    else
        fail "$((dirs_total - dirs_ok)) directories missing"
    fi

    # Check critical commands
    info "Checking system commands..."
    cmds_ok=0
    for cmd in python3 pip3 sqlite3 wget curl; do
        if command -v $cmd >/dev/null 2>&1; then
            ((cmds_ok++))
        else
            fail "Command missing: $cmd"
        fi
    done

    # Special check for nginx (may be in /usr/sbin)
    if command -v nginx >/dev/null 2>&1 || [ -x /usr/sbin/nginx ]; then
        ((cmds_ok++))
    else
        fail "Command missing: nginx"
    fi

    # Special check for ntpdate (may be in /usr/sbin)
    if command -v ntpdate >/dev/null 2>&1 || [ -x /usr/sbin/ntpdate ]; then
        ((cmds_ok++))
    else
        warn "Command missing: ntpdate (optional, using rdate)"
        ((cmds_ok++))  # Don't fail on ntpdate
    fi

    if [ $cmds_ok -ge 6 ]; then
        pass "Critical commands available ($cmds_ok/7)"
    else
        fail "Missing $((7 - cmds_ok)) critical commands"
    fi

    # Check compression tool based on config
    info "Checking compression algorithm..."
    if [ -f /opt/thin-server/config.env ]; then
        source /opt/thin-server/config.env
        _compression_pkg="${COMPRESSION_PKG:-}"
        _compression_algo="${COMPRESSION_ALGO:-zstd}"

        if [ -z "$_compression_pkg" ]; then
            # Determine package from algorithm
            case "$_compression_algo" in
                pigz) _compression_pkg="pigz" ;;
                zstd*) _compression_pkg="zstd" ;;
                lz4) _compression_pkg="liblz4-tool" ;;
                *) _compression_pkg="zstd" ;;
            esac
        fi

        # Check binary (not package name)
        _comp_binary=""
        case "$_compression_algo" in
            pigz) _comp_binary="pigz" ;;
            zstd*) _comp_binary="zstd" ;;
            lz4) _comp_binary="lz4" ;;
            *) _comp_binary="zstd" ;;
        esac

        if command -v $_comp_binary >/dev/null 2>&1; then
            pass "Compression tool: $_comp_binary ($_compression_algo, package: $_compression_pkg)"
        else
            fail "Compression tool missing: $_comp_binary (package: $_compression_pkg required for $_compression_algo)"
        fi
    else
        warn "config.env not found, skipping compression check"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Module 02 - Initramfs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check initramfs files - base + all variants
    info "Checking initramfs files..."

    # Base initramfs
    if [ -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
        initrd_size=$(stat -c "%s" "$WEB_ROOT/initrds/initrd-minimal.img" 2>/dev/null || stat -f "%z" "$WEB_ROOT/initrds/initrd-minimal.img" 2>/dev/null || echo "0")
        if [ "$initrd_size" -lt 10000000 ]; then
            fail "Base initramfs too small: $initrd_size bytes"
        else
            pass "Base initramfs exists ($(du -h "$WEB_ROOT/initrds/initrd-minimal.img" | cut -f1))"
        fi
    else
        fail "Base initramfs NOT FOUND"
    fi

    # Check GPU variants
    _variants_found=0
    for _variant in vmware intel universal autodetect; do
        _variant_file="$WEB_ROOT/initrds/initrd-${_variant}.img"
        if [ -f "$_variant_file" ]; then
            _variant_size=$(du -h "$_variant_file" | cut -f1)

            # Check if it's a symlink
            if [ -L "$_variant_file" ]; then
                _target=$(readlink "$_variant_file")
                pass "GPU variant (${_variant}): $_variant_size (→ $_target)"
            else
                pass "GPU variant (${_variant}): $_variant_size"
            fi
            ((_variants_found++))
        else
            warn "GPU variant missing: initrd-${_variant}.img"
        fi
    done

    if [ $_variants_found -eq 5 ]; then
        pass "All 5 GPU variants present"
    elif [ $_variants_found -gt 0 ]; then
        warn "Only $_variants_found/5 GPU variants found"
    else
        fail "No GPU variants found!"
    fi

    # Check if ntpdate is in initramfs (only if initramfs exists)
    if [ -f "$WEB_ROOT/initrds/initrd-minimal.img" ]; then
        info "Checking NTP tools in initramfs..."
        temp_check="/tmp/verify-initramfs-ntp-$$"
        rm -rf "$temp_check"
        mkdir -p "$temp_check"

        # Determine decompression command
        _decompress_cmd="gunzip -c"
        if [ -f /opt/thin-server/config.env ]; then
            source /opt/thin-server/config.env
            _decompress_cmd="${DECOMPRESSION_CMD:-gunzip -c}"
        fi

        if cd "$temp_check" 2>/dev/null; then
            if $_decompress_cmd "$WEB_ROOT/initrds/initrd-minimal.img" 2>/dev/null | cpio -idm --quiet 2>/dev/null; then
                # Check ntpdate binary
                if [ -f "./usr/bin/ntpdate" ]; then
                    ntpdate_size=$(stat -c%s ./usr/bin/ntpdate 2>/dev/null || stat -f%z ./usr/bin/ntpdate 2>/dev/null || echo "0")
                    if [ "$ntpdate_size" -lt 1000 ]; then
                        warn "ntpdate binary is suspiciously small ($ntpdate_size bytes)"
                    else
                        pass "ntpdate binary exists at usr/bin ($ntpdate_size bytes)"
                    fi
                elif [ -f "./usr/sbin/ntpdate" ]; then
                    ntpdate_size=$(stat -c%s ./usr/sbin/ntpdate 2>/dev/null || stat -f%z ./usr/sbin/ntpdate 2>/dev/null || echo "0")
                    if [ "$ntpdate_size" -lt 1000 ]; then
                        warn "ntpdate binary is suspiciously small ($ntpdate_size bytes)"
                    else
                        pass "ntpdate binary exists at usr/sbin ($ntpdate_size bytes)"
                    fi
                else
                    fail "ntpdate binary NOT FOUND in initramfs"
                    warn "  Fix: Run 'sudo ./install.sh update 02-initramfs' to rebuild"
                fi
            else
                warn "Could not extract initramfs for NTP check"
            fi

            cd - >/dev/null 2>&1
            rm -rf "$temp_check"
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Module 03 - Web Panel"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check Python modules
    info "Checking Python dependencies..."
    python_modules_ok=0
    for module in flask flask_sqlalchemy werkzeug pytz click cryptography; do
        if python3 -c "import $module" 2>/dev/null; then
            ((python_modules_ok++))
        else
            if [[ "$module" == "click" ]] || [[ "$module" == "cryptography" ]]; then
                warn "Python module missing: $module (optional)"
            else
                fail "Python module MISSING: $module (critical)"
            fi
        fi
    done
    if [ $python_modules_ok -ge 4 ]; then
        pass "Python modules installed ($python_modules_ok/6)"
    else
        fail "Missing $((6 - python_modules_ok)) Python modules"
    fi

    # Check Flask application files
    info "Checking Flask application files..."
    app_files_ok=0
    for file in app.py config.py models.py utils.py cli.py; do
        if [ -f "/opt/thinclient-manager/$file" ]; then
            ((app_files_ok++))
        else
            fail "Flask file missing: $file"
        fi
    done
    if [ $app_files_ok -eq 5 ]; then
        pass "All Flask application files present (5/5)"
    else
        fail "$((5 - app_files_ok)) Flask files missing"
    fi

    # Check API files
    info "Checking API files..."
    api_files=$(find /opt/thinclient-manager/api -name "*.py" 2>/dev/null | wc -l)
    if [ $api_files -ge 6 ]; then
        pass "API files present ($api_files files)"
    else
        fail "API files incomplete ($api_files files, expected 6+)"
    fi

    # Check templates
    info "Checking HTML templates..."
    templates_ok=0
    for template in base.html login.html index.html; do
        if [ -f "/opt/thinclient-manager/templates/$template" ]; then
            ((templates_ok++))
        else
            fail "Template missing: $template"
        fi
    done
    if [ $templates_ok -eq 3 ]; then
        pass "All critical templates present (3/3)"
    else
        fail "$((3 - templates_ok)) templates missing"
    fi

    # Check database structure
    info "Checking database structure..."
    if [ -f "/opt/thinclient-manager/db/clients.db" ]; then
        tables=$(sqlite3 "/opt/thinclient-manager/db/clients.db" ".tables" 2>/dev/null)
        expected_tables=("admin" "client" "client_log" "audit_log" "system_settings")
        tables_found=0

        for table in "${expected_tables[@]}"; do
            if echo "$tables" | grep -q "$table"; then
                ((tables_found++))
            else
                fail "Database table missing: $table"
            fi
        done

        if [ $tables_found -eq ${#expected_tables[@]} ]; then
            pass "All database tables present ($tables_found/${#expected_tables[@]})"
        else
            fail "$((${#expected_tables[@]} - tables_found)) database tables missing"
        fi
    else
        fail "Database file NOT FOUND"
    fi

    # Check systemd service
    info "Checking systemd service..."
    if [ -f "/etc/systemd/system/thinclient-manager.service" ]; then
        pass "Systemd service file exists"
    else
        fail "Systemd service file MISSING"
    fi

    # Check Nginx configuration
    info "Checking Nginx configuration..."
    if [ -f "/etc/nginx/sites-available/thinclient" ]; then
        if [ -L "/etc/nginx/sites-enabled/thinclient" ]; then
            pass "Nginx configuration present and enabled"
        else
            warn "Nginx config exists but not enabled"
        fi
    else
        fail "Nginx configuration MISSING"
    fi

    # Test Flask app response
    info "Testing Flask application..."
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/ 2>/dev/null | grep -q "200\|302"; then
        pass "Flask app responding on port 5000"
    else
        fail "Flask app NOT responding"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Module 04 - Boot Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check TFTP configuration
    info "Checking TFTP server configuration..."
    if [ -f "/etc/default/tftpd-hpa" ]; then
        tftp_dir=$(grep "TFTP_DIRECTORY" /etc/default/tftpd-hpa | cut -d'"' -f2)
        # TFTP_ROOT was loaded earlier from config.env
        if [ "$tftp_dir" = "$TFTP_ROOT" ]; then
            pass "TFTP directory configured correctly: $TFTP_ROOT"
        else
            fail "TFTP directory misconfigured: $tftp_dir (expected: $TFTP_ROOT)"
        fi
    else
        fail "TFTP configuration file MISSING"
    fi

    # Check iPXE bootloader
    info "Checking iPXE bootloader..."
    if [ -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
        size=$(stat -c%s "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || stat -f%z "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || echo "0")
        if [ $size -gt 100000 ]; then
            pass "iPXE bootloader present ($size bytes)"
        else
            fail "iPXE bootloader too small ($size bytes)"
        fi
    else
        warn "iPXE bootloader NOT FOUND at $TFTP_ROOT/efi64/bootx64.efi (may not be configured yet)"
    fi

    # Check autoexec.ipxe
    info "Checking autoexec.ipxe..."
    if [ -f "$TFTP_ROOT/autoexec.ipxe" ]; then
        if grep -q "chain http://" "$TFTP_ROOT/autoexec.ipxe"; then
            pass "autoexec.ipxe present and valid"
        else
            fail "autoexec.ipxe has invalid content"
        fi
    else
        warn "autoexec.ipxe NOT FOUND at $TFTP_ROOT/autoexec.ipxe (will be created on first use)"
    fi

    # Check boot.ipxe
    info "Checking boot.ipxe..."
    if [ -f "/var/www/thinclient/boot.ipxe" ]; then
        if grep -q "#!ipxe" "/var/www/thinclient/boot.ipxe"; then
            pass "boot.ipxe present and valid"
        else
            fail "boot.ipxe has invalid content"
        fi
    else
        fail "boot.ipxe NOT FOUND"
    fi

    # Check kernel
    info "Checking kernel..."
    if [ -f "/var/www/thinclient/kernels/vmlinuz" ]; then
        ksize=$(stat -c%s "/var/www/thinclient/kernels/vmlinuz" 2>/dev/null || stat -f%z "/var/www/thinclient/kernels/vmlinuz" 2>/dev/null || echo "0")
        if [ $ksize -gt 5000000 ]; then
            pass "Kernel present ($(($ksize / 1024 / 1024)) MB)"
        else
            fail "Kernel too small ($ksize bytes)"
        fi
    else
        fail "Kernel NOT FOUND"
    fi

    # Test HTTP boot.ipxe accessibility
    info "Testing HTTP boot file accessibility..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1/boot.ipxe" 2>/dev/null || echo "000")
    if [ "$http_code" = "200" ]; then
        pass "boot.ipxe accessible via HTTP"
    else
        fail "boot.ipxe NOT accessible (HTTP $http_code)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Module 05 - Maintenance"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check database backup cron
    info "Checking database backup cron..."
    if [ -f "/etc/cron.d/thin-server-db-backup" ]; then
        if grep -q "/opt/thin-server/scripts/backup-db.sh" "/etc/cron.d/thin-server-db-backup"; then
            if grep -q "0 2 \* \* \*" "/etc/cron.d/thin-server-db-backup"; then
                pass "Database backup cron configured (daily 2:00 AM)"
            else
                warn "Database backup cron exists but schedule may be wrong"
            fi
        else
            fail "Database backup cron has wrong command"
        fi
    else
        warn "Database backup cron NOT FOUND (will be created manually)"
    fi

    # Check log cleanup cron
    info "Checking log cleanup cron..."
    if [ -f "/etc/cron.daily/thin-server-db-cleanup" ]; then
        if [ -x "/etc/cron.daily/thin-server-db-cleanup" ]; then
            pass "Log cleanup cron configured (daily)"
        else
            fail "Log cleanup cron exists but NOT executable"
        fi
    else
        warn "Log cleanup cron NOT FOUND (created by module 05-maintenance)"
    fi

    # Check backup script
    info "Checking backup script..."
    if [ -f "/opt/thin-server/scripts/backup-db.sh" ]; then
        if [ -x "/opt/thin-server/scripts/backup-db.sh" ]; then
            pass "Backup script present and executable"
        else
            fail "Backup script exists but NOT executable"
        fi
    else
        warn "Backup script NOT FOUND"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Services Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check services
    for service in nginx tftpd-hpa thinclient-manager; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            pass "$service is running"
        else
            fail "$service is NOT running"
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Critical Files"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Boot files
    if [ -f "/var/www/thinclient/boot.ipxe" ]; then
        pass "boot.ipxe exists"
    else
        fail "boot.ipxe NOT FOUND"
    fi

    if [ -f "/var/www/thinclient/kernels/vmlinuz" ]; then
        size=$(du -h "/var/www/thinclient/kernels/vmlinuz" 2>/dev/null | cut -f1)
        pass "kernel exists ($size)"
    else
        fail "kernel NOT FOUND"
    fi

    if [ -f "/var/www/thinclient/initrds/initrd-minimal.img" ]; then
        size=$(du -h "/var/www/thinclient/initrds/initrd-minimal.img" 2>/dev/null | cut -f1)
        pass "initrd exists ($size)"
    else
        fail "initrd NOT FOUND"
    fi

    # Flask app
    if [ -f "/opt/thinclient-manager/app.py" ]; then
        pass "Flask app installed"
    else
        fail "Flask app NOT FOUND"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Database"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    #Check database directory permissions (moved from --pre to --post)
    if [ -d "/opt/thinclient-manager/db" ]; then
        if [ -w "/opt/thinclient-manager/db" ]; then
            pass "Database directory writable"
        else
            fail "Database directory NOT writable"
            echo "   Fix: sudo chmod 755 /opt/thinclient-manager/db"
        fi
    else
        fail "Database directory NOT FOUND"
    fi

    if [ -f "/opt/thinclient-manager/db/clients.db" ]; then
        db_size=$(du -h "/opt/thinclient-manager/db/clients.db" 2>/dev/null | cut -f1)
        client_count=$(sqlite3 "/opt/thinclient-manager/db/clients.db" "SELECT COUNT(*) FROM client;" 2>/dev/null || echo "0")
        pass "Database exists ($db_size, $client_count clients)"

        # Check tables
        tables=$(sqlite3 "/opt/thinclient-manager/db/clients.db" ".tables" 2>/dev/null)
        if echo "$tables" | grep -q "client"; then
            pass "Database tables created"
        else
            fail "Database tables MISSING"
        fi

        #Database integrity check
        integrity=$(sqlite3 "/opt/thinclient-manager/db/clients.db" "PRAGMA integrity_check;" 2>/dev/null)
        if [ "$integrity" = "ok" ]; then
            pass "Database integrity OK"
        else
            fail "Database integrity check FAILED: $integrity"
        fi

        #Admin user exists check
        admin_count=$(sqlite3 "/opt/thinclient-manager/db/clients.db" "SELECT COUNT(*) FROM admin;" 2>/dev/null || echo "0")
        if [ "$admin_count" -gt 0 ]; then
            pass "Admin user exists ($admin_count admins)"
        else
            fail "NO ADMIN USER - cannot login to web panel!"
            echo "   Fix: cd /opt/thinclient-manager && python3 cli.py admin create USERNAME PASSWORD"
        fi
    else
        fail "Database NOT FOUND"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Cron Jobs"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "/etc/cron.d/thin-server-db-backup" ]; then
        pass "Database backup cron installed"
    else
        warn "Database backup cron NOT FOUND (created by module 05-maintenance)"
    fi

    if [ -f "/etc/cron.daily/thin-server-db-cleanup" ]; then
        pass "Log cleanup cron installed"
    else
        warn "Log cleanup cron NOT FOUND (created by module 05-maintenance)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Network Access"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Try to access web panel
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1 2>/dev/null | grep -q "200\|302"; then
        pass "Web panel accessible (http://127.0.0.1)"
    else
        warn "Web panel NOT accessible"
    fi

    # Check TFTP
    if netstat -uln 2>/dev/null | grep -q ":69 "; then
        pass "TFTP server listening on port 69"
    else
        warn "TFTP server NOT listening"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Extended Validation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ============================================
    # CHECK 1: Listening Ports
    # ============================================
    info "Checking listening ports..."

    # TFTP (UDP 69)
    if ss -ulnp 2>/dev/null | grep -q ":69 " || netstat -ulnp 2>/dev/null | grep -q ":69 "; then
        pass "TFTP listening on UDP 69"
    else
        fail "TFTP NOT listening on UDP 69"
    fi

    # HTTP (TCP 80)
    if ss -tlnp 2>/dev/null | grep -q ":80.*nginx" || netstat -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
        pass "Nginx listening on TCP 80"
    else
        fail "Nginx NOT listening on TCP 80"
    fi

    # Flask (TCP 5000)
    if ss -tlnp 2>/dev/null | grep -q ":5000.*python" || netstat -tlnp 2>/dev/null | grep -q ":5000.*python"; then
        pass "Flask listening on TCP 5000"
    else
        fail "Flask NOT listening on TCP 5000"
    fi

    # ============================================
    # CHECK 2: HTTP Boot Chain Test
    # ============================================
    info "Testing HTTP boot chain..."

    if command -v curl >/dev/null 2>&1; then
        # Test boot.ipxe
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/boot.ipxe 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
            # Check content is valid iPXE
            content=$(curl -s http://127.0.0.1/boot.ipxe 2>/dev/null)
            if echo "$content" | grep -q "#!ipxe"; then
                pass "boot.ipxe accessible and valid (HTTP 200)"
            else
                fail "boot.ipxe accessible but INVALID content"
            fi
        else
            fail "boot.ipxe HTTP test failed (code: $http_code)"
        fi

        # Test kernel
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/kernels/vmlinuz 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
            pass "kernel accessible (HTTP 200)"
        else
            fail "kernel HTTP test failed (code: $http_code)"
        fi

        # Test initramfs
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/initrds/initrd-minimal.img 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ]; then
            pass "initramfs accessible (HTTP 200)"
        else
            fail "initramfs HTTP test failed (code: $http_code)"
        fi
    else
        warn "curl not available - skipping HTTP tests"
    fi

    # ============================================
    # CHECK 3: SERVER_IP Validation
    # ============================================
    info "Validating SERVER_IP configuration..."

    # Load SERVER_IP from config
    SERVER_IP=""
    for config_path in "$SCRIPT_DIR/config.env" "/opt/thin-server/config.env"; do
        if [ -f "$config_path" ]; then
            SERVER_IP=$(grep "^SERVER_IP=" "$config_path" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            [ -n "$SERVER_IP" ] && break
        fi
    done

    if [ -n "$SERVER_IP" ]; then
        # Check if localhost
        if [[ "$SERVER_IP" == "127.0.0.1" ]] || [[ "$SERVER_IP" == "localhost" ]] || [[ "$SERVER_IP" == "::1" ]]; then
            fail "SERVER_IP is localhost ($SERVER_IP) - REMOTE clients will FAIL!"
            warn "Change SERVER_IP to network IP in config.env"
        else
            pass "SERVER_IP is network IP: $SERVER_IP"

            # Check if IP is configured on this machine
            if ip addr 2>/dev/null | grep -q "$SERVER_IP"; then
                pass "SERVER_IP $SERVER_IP is configured on this server"
            else
                warn "SERVER_IP $SERVER_IP is NOT found on this server's interfaces"
                warn "Make sure this is correct and reachable from clients"
            fi
        fi
    else
        fail "SERVER_IP not configured in config.env"
    fi

    # ============================================
    # CHECK 4: Critical File Sizes
    # ============================================
    info "Checking critical file sizes..."

    # Kernel (should be >5MB)
    if [ -f "/var/www/thinclient/kernels/vmlinuz" ]; then
        kernel_size=$(stat -c%s "/var/www/thinclient/kernels/vmlinuz" 2>/dev/null || stat -f%z "/var/www/thinclient/kernels/vmlinuz" 2>/dev/null || echo "0")
        kernel_mb=$((kernel_size / 1024 / 1024))
        if [ "$kernel_size" -gt 5000000 ]; then
            pass "Kernel size: ${kernel_mb} MB (valid)"
        else
            fail "Kernel too small: ${kernel_mb} MB (expected >5MB)"
        fi
    fi

    # Initramfs - check base + all GPU variants
    info "Checking initramfs variants..."

    # Determine minimum size based on compression algorithm
    # After removing AMD/NVIDIA support, we have two size categories:
    #   - Base/Universal (software rendering only): smaller, ~40MB+
    #   - GPU-specific (vmware, intel with firmware): larger, ~50MB+
    _compression_algo="${COMPRESSION_ALGO:-gzip}"

    # Base/Universal variant minimums (no GPU firmware)
    case "$_compression_algo" in
        gzip|pigz)
            _min_size_base_mb=70
            ;;
        lz4)
            _min_size_base_mb=70
            ;;
        zstd-fast|zstd-1)
            _min_size_base_mb=50
            ;;
        zstd|zstd-19)
            _min_size_base_mb=40  # Updated: universal/base without GPU firmware
            ;;
        *)
            _min_size_base_mb=40
            ;;
    esac

    # GPU-specific variant minimums (with GPU firmware and modules)
    case "$_compression_algo" in
        gzip|pigz)
            _min_size_gpu_mb=80
            ;;
        lz4)
            _min_size_gpu_mb=80
            ;;
        zstd-fast|zstd-1)
            _min_size_gpu_mb=60
            ;;
        zstd|zstd-19)
            _min_size_gpu_mb=50  # GPU variants with firmware
            ;;
        *)
            _min_size_gpu_mb=50
            ;;
    esac

    _min_size_base_bytes=$((_min_size_base_mb * 1024 * 1024))
    _min_size_gpu_bytes=$((_min_size_gpu_mb * 1024 * 1024))

    # Base initramfs (minimal - no GPU components)
    if [ -f "/var/www/thinclient/initrds/initrd-minimal.img" ]; then
        initrd_size=$(stat -c%s "/var/www/thinclient/initrds/initrd-minimal.img" 2>/dev/null || stat -f%z "/var/www/thinclient/initrds/initrd-minimal.img" 2>/dev/null || echo "0")
        initrd_mb=$((initrd_size / 1024 / 1024))
        if [ "$initrd_size" -gt "$_min_size_base_bytes" ]; then
            pass "Base initramfs (initrd-minimal.img): ${initrd_mb} MB (compression: $_compression_algo)"
        else
            fail "Base initramfs too small: ${initrd_mb} MB (expected >${_min_size_base_mb}MB for $_compression_algo)"
        fi
    else
        fail "Base initramfs missing: initrd-minimal.img"
    fi

    # GPU variants - check all 5
    # Different variants have different minimum sizes:
    #   - universal: software rendering only (~40MB)
    #   - vmware, intel, amd: GPU firmware included (~50MB+ for vmware/intel, ~150-200MB for amd)
    #   - autodetect: symlink to universal
    variants_ok=0
    variants_total=5
    for variant in vmware intel amd universal autodetect; do
        variant_file="/var/www/thinclient/initrds/initrd-${variant}.img"
        if [ -f "$variant_file" ]; then
            variant_size=$(stat -c%s "$variant_file" 2>/dev/null || stat -f%z "$variant_file" 2>/dev/null || echo "0")
            variant_mb=$((variant_size / 1024 / 1024))

            # Determine expected minimum size for this variant
            if [ "$variant" = "universal" ]; then
                _expected_min_bytes=$_min_size_base_bytes
                _expected_min_mb=$_min_size_base_mb
            else
                _expected_min_bytes=$_min_size_gpu_bytes
                _expected_min_mb=$_min_size_gpu_mb
            fi

            # Check if symlink (autodetect → universal)
            if [ -L "$variant_file" ]; then
                target=$(readlink "$variant_file")
                pass "GPU variant ($variant): symlink → $target"
                ((variants_ok++))
            elif [ "$variant_size" -gt "$_expected_min_bytes" ]; then
                pass "GPU variant ($variant): ${variant_mb} MB"
                ((variants_ok++))
            else
                warn "GPU variant ($variant) too small: ${variant_mb} MB (expected >${_expected_min_mb}MB)"
            fi
        else
            warn "GPU variant missing: initrd-${variant}.img"
        fi
    done

    if [ $variants_ok -eq $variants_total ]; then
        pass "All $variants_total GPU variants present and valid"
    elif [ $variants_ok -gt 0 ]; then
        warn "Only $variants_ok/$variants_total GPU variants are valid"
    else
        fail "No GPU variants found (should have 5: vmware, intel, amd, universal, autodetect)"
    fi

    # iPXE bootloader (should be ~1-2MB)
    if [ -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
        ipxe_size=$(stat -c%s "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || stat -f%z "$TFTP_ROOT/efi64/bootx64.efi" 2>/dev/null || echo "0")
        ipxe_kb=$((ipxe_size / 1024))
        if [ "$ipxe_size" -gt 100000 ] && [ "$ipxe_size" -lt 10000000 ]; then
            pass "iPXE bootloader size: ${ipxe_kb} KB (valid)"
        else
            warn "iPXE bootloader size unusual: ${ipxe_kb} KB (expected 1-2 MB)"
        fi
    fi

    # Database (should be >10KB after init)
    if [ -f "/opt/thinclient-manager/db/clients.db" ]; then
        db_size=$(stat -c%s "/opt/thinclient-manager/db/clients.db" 2>/dev/null || stat -f%z "/opt/thinclient-manager/db/clients.db" 2>/dev/null || echo "0")
        db_kb=$((db_size / 1024))
        if [ "$db_size" -gt 10240 ]; then
            pass "Database size: ${db_kb} KB (valid)"
        else
            warn "Database size small: ${db_kb} KB (may be empty)"
        fi
    fi

    # ============================================
    # CHECK 5: TFTP File Retrieval Test
    # ============================================
    info "Testing TFTP file retrieval..."

    # Create test file
    if [ -w "$TFTP_ROOT" ]; then
        echo "Thin-Server TFTP Test $(date)" > "$TFTP_ROOT/test-verify.txt" 2>/dev/null

        # Try to download it
        if command -v tftp >/dev/null 2>&1; then
            if echo -e "get test-verify.txt /tmp/tftp-test-$$\nquit" | tftp 127.0.0.1 >/dev/null 2>&1; then
                if [ -f "/tmp/tftp-test-$$" ]; then
                    pass "TFTP file retrieval successful"
                    rm -f "/tmp/tftp-test-$$"
                else
                    fail "TFTP download failed - file not created"
                fi
            else
                fail "TFTP download failed - connection error"
            fi
            rm -f "$TFTP_ROOT/test-verify.txt"
        else
            warn "tftp client not available - skipping TFTP test"
            info "Install: apt-get install tftp"
            rm -f "$TFTP_ROOT/test-verify.txt"
        fi
    else
        warn "Cannot write to TFTP_ROOT - skipping TFTP test"
    fi

    # ============================================
    # CHECK 6: NTP Server Accessibility
    # ============================================
    info "Testing NTP server accessibility..."

    # Load NTP_SERVER from config
    NTP_SERVER=""
    for config_path in "$SCRIPT_DIR/config.env" "/opt/thin-server/config.env"; do
        if [ -f "$config_path" ]; then
            NTP_SERVER=$(grep "^NTP_SERVER=" "$config_path" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            [ -n "$NTP_SERVER" ] && break
        fi
    done

    if [ -n "$NTP_SERVER" ]; then
        # Try to ping NTP server
        if ping -c 1 -W 2 "$NTP_SERVER" >/dev/null 2>&1; then
            pass "NTP server $NTP_SERVER is reachable"

            # Try NTP sync (if ntpdate available)
            if command -v ntpdate >/dev/null 2>&1 || [ -x /usr/sbin/ntpdate ]; then
                ntpdate_cmd=$(command -v ntpdate 2>/dev/null || echo /usr/sbin/ntpdate)
                if $ntpdate_cmd -q "$NTP_SERVER" >/dev/null 2>&1; then
                    pass "NTP server $NTP_SERVER responds to time queries"
                else
                    warn "NTP server $NTP_SERVER does not respond to time queries"
                fi
            fi
        else
            fail "NTP server $NTP_SERVER is NOT reachable"
            warn "Clients will fail RDP authentication without time sync!"
        fi
    else
        warn "NTP_SERVER not configured in config.env"
    fi

    # ============================================
    # CHECK 7: Flask API Test
    # ============================================
    info "Testing Flask API endpoints..."

    if command -v curl >/dev/null 2>&1; then
        # Test /api/system/health (no auth required)
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/api/system/health 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ] || [ "$http_code" = "503" ]; then
            pass "API /api/system/health responding (${http_code})"
        else
            warn "API /api/system/health returned: $http_code"
        fi

        # Test health endpoint (doesn't create clients)
        # 200 = healthy, 503 = degraded
        http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/health 2>/dev/null || echo "000")
        if [ "$http_code" = "200" ] || [ "$http_code" = "503" ]; then
            pass "API health endpoint responding (${http_code})"
        else
            fail "API health endpoint failed: $http_code"
        fi
    fi

    # ============================================
    # CHECK 8: RDS Server Accessibility
    # ============================================
    info "Testing RDS server accessibility..."

    # Load RDS_SERVER from config
    RDS_SERVER=""
    for config_path in "$SCRIPT_DIR/config.env" "/opt/thin-server/config.env"; do
        if [ -f "$config_path" ]; then
            RDS_SERVER=$(grep "^RDS_SERVER=" "$config_path" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
            [ -n "$RDS_SERVER" ] && break
        fi
    done

    if [ -n "$RDS_SERVER" ]; then
        # Try to resolve hostname
        if host "$RDS_SERVER" >/dev/null 2>&1 || nslookup "$RDS_SERVER" >/dev/null 2>&1; then
            pass "RDS server $RDS_SERVER resolves in DNS"

            # Try to connect to RDP port (3389)
            if command -v nc >/dev/null 2>&1; then
                if timeout 3 nc -zv "$RDS_SERVER" 3389 >/dev/null 2>&1; then
                    pass "RDS server $RDS_SERVER:3389 is accepting connections"
                else
                    warn "RDS server $RDS_SERVER:3389 is NOT accepting connections"
                fi
            elif command -v telnet >/dev/null 2>&1; then
                if timeout 3 bash -c "echo quit | telnet $RDS_SERVER 3389" >/dev/null 2>&1; then
                    pass "RDS server $RDS_SERVER:3389 is accepting connections"
                else
                    warn "RDS server $RDS_SERVER:3389 is NOT accepting connections"
                fi
            else
                info "nc/telnet not available - skipping RDP port test"
            fi
        else
            fail "RDS server $RDS_SERVER does NOT resolve in DNS"
            warn "Clients will not be able to connect!"
        fi
    else
        warn "RDS_SERVER not configured in config.env"
    fi

    # ============================================
    # CHECK 9: File Permissions
    # ============================================
    info "Checking file permissions..."

    # TFTP files should be readable by tftp user
    if [ -f "$TFTP_ROOT/efi64/bootx64.efi" ]; then
        if [ -r "$TFTP_ROOT/efi64/bootx64.efi" ]; then
            pass "bootx64.efi is readable"
        else
            fail "bootx64.efi is NOT readable (check permissions)"
        fi
    fi

    # Web files should be readable by www-data
    if [ -f "/var/www/thinclient/boot.ipxe" ]; then
        if [ -r "/var/www/thinclient/boot.ipxe" ]; then
            pass "boot.ipxe is readable"
        else
            fail "boot.ipxe is NOT readable (check permissions)"
        fi
    fi

    # Database should NOT be world-readable (security)
    if [ -f "/opt/thinclient-manager/db/clients.db" ]; then
        perms=$(stat -c%a "/opt/thinclient-manager/db/clients.db" 2>/dev/null || stat -f%Lp "/opt/thinclient-manager/db/clients.db" 2>/dev/null || echo "000")
        # Check if world-readable (last digit should be 0 or 4)
        last_digit="${perms: -1}"
        if [ "$last_digit" -le 4 ]; then
            pass "Database permissions secure: $perms"
        else
            warn "Database permissions too open: $perms (should be 644 or 640)"
        fi
    fi

    # ============================================
    # CHECK 10: Disk Space
    # ============================================
    info "Checking disk space..."

    # Check /var/log/thinclient (logs can grow)
    if [ -d "/var/log/thinclient" ]; then
        log_space=$(df -h /var/log/thinclient 2>/dev/null | awk 'NR==2 {print $4}')
        log_space_mb=$(df -m /var/log/thinclient 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$log_space_mb" ] && [ "$log_space_mb" -gt 1000 ]; then
            pass "Log partition has ${log_space} available"
        elif [ -n "$log_space" ]; then
            warn "Log partition has only ${log_space} available (logs may fill up)"
        fi
    fi

    # Check /opt (for backups)
    if [ -d "/opt" ]; then
        opt_space=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}')
        opt_space_mb=$(df -m /opt 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$opt_space_mb" ] && [ "$opt_space_mb" -gt 5000 ]; then
            pass "/opt partition has ${opt_space} available"
        elif [ -n "$opt_space" ]; then
            warn "/opt partition has only ${opt_space} available (backups may fail)"
        fi
    fi

    # Check /var/www (for boot files)
    if [ -d "/var/www" ]; then
        www_space=$(df -h /var/www 2>/dev/null | awk 'NR==2 {print $4}')
        www_space_mb=$(df -m /var/www 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -n "$www_space_mb" ] && [ "$www_space_mb" -gt 500 ]; then
            pass "/var/www partition has ${www_space} available"
        elif [ -n "$www_space" ]; then
            fail "/var/www partition has only ${www_space} available (not enough for boot files)"
        fi
    fi

    # ============================================
    # CHECK 10: Nginx Configuration Test
    # ============================================
    info "Testing Nginx configuration..."

    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>&1 | grep -q "syntax is ok"; then
            pass "Nginx configuration is valid"
        else
            fail "Nginx configuration has ERRORS"
            echo "   Run: nginx -t"
        fi
    fi

    # ============================================
    # CHECK 11: Config.env Validation
    # ============================================
    info "Validating config.env critical variables..."

    if [ -f "$SCRIPT_DIR/config.env" ]; then
        set -a
        source "$SCRIPT_DIR/config.env"
        set +a

        # Check SERVER_IP is not empty and valid format
        if [ -n "$SERVER_IP" ]; then
            if echo "$SERVER_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                pass "SERVER_IP is valid: $SERVER_IP"
            else
                fail "SERVER_IP has invalid format: $SERVER_IP"
            fi
        else
            fail "SERVER_IP is EMPTY in config.env"
        fi

        # Check RDS_SERVER is not empty
        if [ -n "$RDS_SERVER" ]; then
            pass "RDS_SERVER is configured: $RDS_SERVER"
        else
            warn "RDS_SERVER is EMPTY in config.env"
        fi

        # Check NTP_SERVER is not empty
        if [ -n "$NTP_SERVER" ]; then
            pass "NTP_SERVER is configured: $NTP_SERVER"
        else
            warn "NTP_SERVER is EMPTY in config.env"
        fi
    fi

    # ============================================
    # CHECK 12: FreeRDP Version Check
    # ============================================
    info "Checking FreeRDP version and capabilities..."

    if command -v xfreerdp >/dev/null 2>&1; then
        freerdp_version=$(xfreerdp /version 2>&1 | grep "FreeRDP" | head -1)
        if [ -n "$freerdp_version" ]; then
            pass "FreeRDP installed: $freerdp_version"

            # Check if FreeRDP supports critical options
            if xfreerdp /help 2>&1 | grep -q "/cert:"; then
                pass "FreeRDP supports /cert: options"
            else
                warn "FreeRDP may not support /cert: SSL bypass"
            fi
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "POST-INSTALL: Initramfs Dependencies Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Critical binaries that must work in initramfs
    CRITICAL_BINARIES=(
        "usr/bin/xfreerdp"
        "usr/lib/xorg/Xorg"
        "bin/ip"
        "bin/wget"
        "sbin/udevd"
        "bin/udevadm"
        "bin/busybox"         # CRITICAL - базова система
        "sbin/modprobe"       # CRITICAL - для модулів
        "sbin/ldconfig"       # Для бібліотек
        "usr/bin/openbox"     # Window manager
        "usr/bin/xkbcomp"     # Keyboard layout
        "usr/bin/xdpyinfo"    # X diagnostics
    )

    # Binaries that can be in multiple locations (check separately)
    ALTERNATIVE_BINARIES=(
        "ntpdate:usr/bin/ntpdate:usr/sbin/ntpdate"
        "rdate:usr/bin/rdate:usr/sbin/rdate"
    )

    # Critical libraries for NTP and network
    CRITICAL_LIBS=(
        "libnss_dns.so.2"     # DNS resolution
        "libnss_files.so.2"   # Local files (/etc/hosts)
        "libresolv.so.2"      # Resolver library
    )

    # Additional libraries to check (optional, warnings only)
    ADDITIONAL_LIBS=(
        "libbpf.so.1"         # Для ip команди (обов'язкова в Debian 12)
        "libnsl.so.1"         # Old NTP dependency (optional, auto-copied by ldd)
    )

    # Extract initramfs to temp dir for checking
    if [ -f "/var/www/thinclient/initrds/initrd-minimal.img" ]; then
        TEMP_CHECK="/tmp/initramfs-verify-$$"
        mkdir -p "$TEMP_CHECK"
        cd "$TEMP_CHECK"

        #Use correct decompression command based on config
        info "Extracting initramfs (this may take 30-60 seconds)..."

        # Determine decompression command
        decompress_cmd="zcat"
        if [ -f /opt/thin-server/config.env ]; then
            source /opt/thin-server/config.env
            decompress_cmd="${DECOMPRESSION_CMD:-zcat}"
        fi

        # Extract initramfs with progress
        ($decompress_cmd "/var/www/thinclient/initrds/initrd-minimal.img" 2>/dev/null | cpio -idm 2>/dev/null) &
        extract_pid=$!

        # Show spinner while extracting
        spinstr='|/-\'
        while kill -0 $extract_pid 2>/dev/null; do
            temp=${spinstr#?}
            printf "\r  Extracting... [%c]" "$spinstr"
            spinstr=$temp${spinstr%"$temp"}
            sleep 0.1
        done
        printf "\r  Extracting... done!     \n"

        wait $extract_pid
        extract_result=$?

        if [ $extract_result -eq 0 ]; then
            pass "Initramfs extracted successfully"
            info "Checking initramfs contents..."

            # Check critical binaries and their dependencies
            info "Checking critical binaries and dependencies..."
            missing_deps=0
            binaries_checked=0
            for binary in "${CRITICAL_BINARIES[@]}"; do
                # Use -e (exists) instead of -f (regular file) to support scripts and symlinks
                if [ -e "$binary" ] || [ -L "$binary" ]; then
                    ((binaries_checked++))
                    # Skip ldd check for shell scripts
                    if file "$binary" 2>/dev/null | grep -q "shell script"; then
                        # It's a shell script - just check if it's executable
                        if [ -x "$binary" ] || [ -r "$binary" ]; then
                            : # Script is OK
                        else
                            warn "$(basename $binary) script is not executable/readable"
                        fi
                    else
                        # Binary - check dependencies with ldd
                        missing=$(ldd "$binary" 2>/dev/null | grep "not found" | wc -l)
                        if [ "$missing" -gt 0 ]; then
                            fail "$(basename $binary) has missing dependencies:"
                            ldd "$binary" 2>/dev/null | grep "not found" | while read line; do
                                echo "      $line"
                            done
                            ((missing_deps++))
                        fi
                    fi
                else
                    # Some binaries are optional
                    case "$binary" in
                        *openbox*|*xdpyinfo*|*xkbcomp*)
                            warn "$(basename $binary) not found (optional)"
                            ;;
                        *)
                            fail "$(basename $binary) NOT FOUND (critical!)"
                            ((missing_deps++))
                            ;;
                    esac
                fi
            done

            if [ $missing_deps -eq 0 ]; then
                pass "All $binaries_checked critical binaries have dependencies ($binaries_checked checked)"
            else
                fail "$missing_deps binaries missing or have missing dependencies"
            fi

            # Check alternative location binaries (ntpdate, rdate)
            for alt_spec in "${ALTERNATIVE_BINARIES[@]}"; do
                IFS=':' read -r name path1 path2 <<< "$alt_spec"
                if [ -e "$path1" ] || [ -L "$path1" ] || [ -e "$path2" ] || [ -L "$path2" ]; then
                    # Found in at least one location
                    : # OK
                else
                    warn "$name not found (optional)"
                fi
            done

            # Check critical libraries exist
            info "Checking critical libraries..."
            missing_libs=0
            for lib in "${CRITICAL_LIBS[@]}"; do
                if find lib* usr/lib* -name "$lib" 2>/dev/null | grep -q .; then
                    : # Library found, do nothing
                else
                    fail "Critical library MISSING: $lib"
                    ((missing_libs++))
                fi
            done

            if [ $missing_libs -eq 0 ]; then
                pass "All ${#CRITICAL_LIBS[@]} critical libraries present"
            else
                fail "$missing_libs critical libraries MISSING"
            fi

            # Check additional libraries (warnings only)
            missing_additional=0
            missing_lib_names=()
            for lib in "${ADDITIONAL_LIBS[@]}"; do
                if find lib* usr/lib* -name "$lib" 2>/dev/null | grep -q .; then
                    : # Library found
                else
                    ((missing_additional++))
                    missing_lib_names+=("$lib")
                fi
            done
            if [ $missing_additional -eq 0 ]; then
                pass "All ${#ADDITIONAL_LIBS[@]} additional libraries present"
            else
                warn "$missing_additional additional libraries missing (may cause issues):"
                for lib in "${missing_lib_names[@]}"; do
                    echo "      - $lib"
                done
            fi

            # Check BusyBox symlinks
            info "Checking BusyBox setup..."
            if [ -f "bin/busybox" ]; then
                symlink_count=$(find bin/ -type l -lname '*busybox' 2>/dev/null | wc -l)
                if [ $symlink_count -gt 20 ]; then
                    pass "BusyBox installed with $symlink_count symlinks"
                else
                    warn "BusyBox has only $symlink_count symlinks (expected 20+)"
                fi
            else
                fail "BusyBox NOT FOUND"
            fi

            # Check if ntpdate is present with correct path (can be file or symlink)
            info "Checking NTP tools..."
            if [ -e "usr/bin/ntpdate" ] || [ -L "usr/bin/ntpdate" ] || [ -e "usr/sbin/ntpdate" ] || [ -L "usr/sbin/ntpdate" ]; then
                ntp_bin="usr/sbin/ntpdate"
                [ -e "usr/bin/ntpdate" ] || [ -L "usr/bin/ntpdate" ] && ntp_bin="usr/bin/ntpdate"

                # Check if it's a symlink
                if [ -L "$ntp_bin" ]; then
                    local link_target=$(readlink "$ntp_bin")
                    pass "ntpdate present as symlink → $link_target"
                else
                    # Check ntpdate dependencies (all auto-copied by ldd)
                    if ldd "$ntp_bin" 2>/dev/null | grep -q "not found"; then
                        fail "ntpdate has missing dependencies!"
                        ldd "$ntp_bin" 2>/dev/null | grep "not found"
                    else
                        pass "ntpdate dependencies OK"
                    fi
                fi
            else
                # ntpdate is optional - rdate is the fallback
                if [ -e "usr/bin/rdate" ] || [ -L "usr/bin/rdate" ]; then
                    warn "ntpdate NOT FOUND - using rdate fallback for time sync"
                else
                    fail "Neither ntpdate nor rdate found - time sync will fail!"
                fi
            fi

            # Check FreeRDP
            info "Checking FreeRDP..."
            if [ -f "usr/bin/xfreerdp" ]; then
                if ldd "usr/bin/xfreerdp" 2>/dev/null | grep -q "not found"; then
                    fail "xfreerdp has missing dependencies:"
                    ldd "usr/bin/xfreerdp" 2>/dev/null | grep "not found"
                else
                    pass "xfreerdp dependencies OK"

                    # Check FreeRDP libs directory (optional - plugins may be built-in)
                    if [ -d "usr/local/lib/freerdp3" ]; then
                        freerdp_libs=$(find usr/local/lib/freerdp3 -name "*.so" 2>/dev/null | wc -l)
                        if [ "$freerdp_libs" -gt 0 ]; then
                            pass "FreeRDP libs directory exists ($freerdp_libs plugins)"
                        else
                            info "FreeRDP libs directory exists but is empty (OK if plugins built-in)"
                        fi
                    else
                        # This is OK - FreeRDP 3.x may have built-in plugins
                        info "FreeRDP plugins built-in (no separate libs directory - normal for FreeRDP 3.x)"
                    fi
                fi
            else
                fail "xfreerdp NOT FOUND"
            fi

            # Check X.org
            info "Checking X.org..."
            if [ -f "usr/lib/xorg/Xorg" ]; then
                if ldd "usr/lib/xorg/Xorg" 2>/dev/null | grep -q "not found"; then
                    fail "Xorg has missing dependencies:"
                    ldd "usr/lib/xorg/Xorg" 2>/dev/null | grep "not found"
                else
                    pass "Xorg dependencies OK"
                fi
            else
                fail "Xorg NOT FOUND"
            fi

            # Check X.org modules
            info "Checking X.org modules..."
            xorg_modules_ok=0
            xorg_modules_missing=0

            # Input drivers (critical)
            if [ -f "usr/lib/xorg/modules/input/libinput_drv.so" ]; then
                pass "libinput X.org driver present"
                ((xorg_modules_ok++))
            else
                fail "libinput_drv.so MISSING (critical for input!)"
                ((xorg_modules_missing++))
            fi

            if [ -f "usr/lib/xorg/modules/input/evdev_drv.so" ]; then
                pass "evdev X.org driver present"
                ((xorg_modules_ok++))
            else
                warn "evdev_drv.so missing (fallback driver)"
                ((xorg_modules_missing++))
            fi

            # Graphics drivers
            if [ -f "usr/lib/xorg/modules/drivers/modesetting_drv.so" ]; then
                pass "modesetting X.org driver present"
                ((xorg_modules_ok++))
            else
                fail "modesetting_drv.so MISSING (critical for display!)"
                ((xorg_modules_missing++))
            fi

            # Extensions
            if [ -f "usr/lib/xorg/modules/extensions/libglx.so" ]; then
                pass "libglx.so present"
                ((xorg_modules_ok++))
            else
                warn "libglx.so missing (OpenGL may not work)"
            fi

            # Check kernel modules exist
            info "Checking kernel modules..."
            CRITICAL_MODULES=(
                "evdev"      # Critical for input
                "e1000"      # Network
                "r8169"      # Network
                "drm"        # Graphics
            )

            missing_mods=0
            for mod in "${CRITICAL_MODULES[@]}"; do
                if find lib/modules -name "${mod}.ko" -o -name "${mod}.ko.xz" 2>/dev/null | grep -q .; then
                    : # Module found
                else
                    fail "Kernel module MISSING: ${mod}.ko"
                    ((missing_mods++))
                fi
            done

            if [ $missing_mods -eq 0 ]; then
                pass "All ${#CRITICAL_MODULES[@]} critical kernel modules present"
            else
                fail "$missing_mods critical kernel modules MISSING"
            fi

            # Check kernel module directories
            info "Checking kernel module directories..."
            kver=$(ls lib/modules 2>/dev/null | head -1)
            if [ -n "$kver" ]; then
                module_dirs=0
                [ -d "lib/modules/$kver/kernel/drivers/net" ] && ((module_dirs++))
                [ -d "lib/modules/$kver/kernel/drivers/gpu" ] && ((module_dirs++))
                [ -d "lib/modules/$kver/kernel/drivers/usb" ] && ((module_dirs++))
                [ -d "lib/modules/$kver/kernel/drivers/hid" ] && ((module_dirs++))
                [ -d "lib/modules/$kver/kernel/drivers/input" ] && ((module_dirs++))

                if [ $module_dirs -ge 4 ]; then
                    pass "Kernel module directories present ($module_dirs/5)"
                else
                    warn "Some kernel module directories missing ($module_dirs/5)"
                fi
            else
                fail "No kernel modules directory found!"
            fi

            # Check module tools
            info "Checking module tools..."
            if [ -f "sbin/modprobe" ]; then
                pass "modprobe available"
            else
                fail "modprobe MISSING - cannot load modules!"
            fi

            if [ -f "sbin/depmod" ]; then
                pass "depmod available"
            else
                warn "depmod missing"
            fi

            # Check config files
            info "Checking config files..."
            config_ok=0
            [ -f "etc/passwd" ] && ((config_ok++))
            [ -f "etc/group" ] && ((config_ok++))
            [ -f "etc/hostname" ] && ((config_ok++))
            [ -f "etc/nsswitch.conf" ] && ((config_ok++))
            [ -f "etc/udhcpc.script" ] && ((config_ok++))
            [ -f "etc/X11/xorg.conf" ] && ((config_ok++))

            if [ $config_ok -ge 5 ]; then
                pass "Config files present ($config_ok/6)"
            else
                warn "Some config files missing ($config_ok/6)"
            fi

            # Check udev rules
            if [ -f "etc/udev/rules.d/99-input.rules" ]; then
                pass "udev input rules present"
            else
                warn "udev input rules missing"
            fi

            # Check timezone data
            if [ -f "usr/share/zoneinfo/Europe/Kyiv" ] && [ -f "etc/timezone" ]; then
                pass "Timezone data present"
            else
                warn "Timezone data missing"
            fi

            # Check XKB data
            if [ -d "usr/share/X11/xkb" ]; then
                xkb_files=$(find usr/share/X11/xkb -type f 2>/dev/null | wc -l)
                if [ $xkb_files -gt 10 ]; then
                    pass "XKB keyboard data present ($xkb_files files)"
                else
                    warn "XKB data incomplete ($xkb_files files)"
                fi
            else
                fail "XKB data MISSING - keyboard won't work!"
            fi

            # Check init script
            if [ -f "init" ] && [ -x "init" ]; then
                pass "Init script present and executable"
            else
                fail "Init script missing or not executable!"
            fi

        else
            fail "Failed to extract initramfs for verification!"
        fi

        # Cleanup
        cd /
        rm -rf "$TEMP_CHECK"
    else
        fail "initramfs not found at /var/www/thinclient/initrds/initrd-minimal.img"
    fi

    echo ""
fi

# ============================================
# 8. SUMMARY
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo -e "${GREEN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✓ ALL CHECKS PASSED                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}System is ready for deployment!${NC}"
    echo ""
    if [ "$MODE" = "--pre" ]; then
        echo "Next steps:"
        echo "  1. Run: sudo bash deploy.sh"
        echo "  2. Monitor logs: tail -f /var/log/thinclient/thin-server-install-*.log"
    fi
    echo ""
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo -e "${YELLOW}╔═══════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠ PASSED WITH WARNINGS               ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
    echo ""
    if [ "$MODE" = "--pre" ]; then
        echo "You can proceed with deployment."
        echo "Warnings above are expected - Python dependencies will be installed during deployment."
    else
        echo "Review warnings above - some optional components may have issues."
    fi
    echo ""
    exit 0
else
    echo -e "${RED}╔═══════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ✗ VERIFICATION FAILED                 ║${NC}"
    echo -e "${RED}╚═══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}Errors: $ERRORS${NC}"
    echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
    echo ""
    echo "DO NOT DEPLOY until all errors are fixed!"
    echo "Review the errors above and fix them."
    echo ""
    exit 1
fi
