#!/bin/bash
#
# Thin-Server Deployment Reports Generator v1.0.0
# Генерує детальні звіти після встановлення системи
#
# Звіти створюються в: /opt/thin-server/reports/TIMESTAMP/
#
# Файли звітів:
#   1. deployment-validation-report.txt  - всі перевірки з результатами
#   2. installed-packages-report.txt     - встановлені/невстановлені пакети
#   3. initramfs-contents-report.txt     - вміст образу (драйвери, бібліотеки)
#   4. services-status-report.txt        - стан сервісів, порти, автостарт
#   5. system-configuration-report.txt   - конфігурація системи

#Don't exit on errors - we want to generate all reports
set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

#Only run on Linux
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ ERROR: This script must run on Linux server!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Detected OS: $(uname -s)"
    echo "This script generates deployment reports for Thin-Server"
    echo "and must be executed on the Debian server."
    echo ""
    echo "To generate reports:"
    echo "  1. SSH to your Debian server"
    echo "  2. cd /opt/thin-server"
    echo "  3. sudo bash deploy.sh --full"
    echo ""
    exit 1
fi

# Ensure PATH includes system binaries
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Load config
if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
elif [ -f "/opt/thin-server/config.env" ]; then
    source "/opt/thin-server/config.env"
fi

# Set defaults if not loaded
TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"
WEB_ROOT="${WEB_ROOT:-/var/www/thinclient}"
APP_DIR="${APP_DIR:-/opt/thinclient-manager}"
DB_DIR="${DB_DIR:-/opt/thinclient-manager/db}"

# Report directory
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

#Support both server and local development environments
if [ -w "/opt/thin-server" ] 2>/dev/null || [ -d "/opt/thin-server" ]; then
    # Production server - use /opt/thin-server/reports
    REPORT_DIR="/opt/thin-server/reports/$TIMESTAMP"
else
    # Local development - use project directory
    REPORT_DIR="$SCRIPT_DIR/reports/$TIMESTAMP"
fi

mkdir -p "$REPORT_DIR" || {
    echo "ERROR: Cannot create report directory: $REPORT_DIR"
    echo "Please run with appropriate permissions or check directory access"
    exit 1
}

echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Thin-Server Deployment Reports Generator v1.0.0          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Generating reports in: ${REPORT_DIR}${NC}"
echo ""

# ============================================
# REPORT 1: DEPLOYMENT VALIDATION
# ============================================
echo -e "${YELLOW}[1/5] Generating deployment validation report...${NC}"

VALIDATION_REPORT="$REPORT_DIR/deployment-validation-report.txt"

cat > "$VALIDATION_REPORT" << 'EOFHEADER'
═══════════════════════════════════════════════════════════════════
  THIN-SERVER DEPLOYMENT VALIDATION REPORT
═══════════════════════════════════════════════════════════════════

EOFHEADER

echo "Generated: $(date)" >> "$VALIDATION_REPORT"
echo "Hostname: $(hostname)" >> "$VALIDATION_REPORT"
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || uname -s)" >> "$VALIDATION_REPORT"
echo "Kernel: $(uname -r)" >> "$VALIDATION_REPORT"
echo "User: $(whoami)" >> "$VALIDATION_REPORT"
echo "Working Dir: $(pwd)" >> "$VALIDATION_REPORT"
echo "Script Location: $SCRIPT_DIR" >> "$VALIDATION_REPORT"
echo "Report Dir: $REPORT_DIR" >> "$VALIDATION_REPORT"
echo "" >> "$VALIDATION_REPORT"
echo "═══════════════════════════════════════════════════════════════════" >> "$VALIDATION_REPORT"
echo "" >> "$VALIDATION_REPORT"

# ============================================
# RUN ALL VERIFICATION SCRIPTS
# ============================================

# 1. Standard verification (verify-installation.sh)
if [ -f "$SCRIPT_DIR/scripts/verify-installation.sh" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "1. STANDARD VERIFICATION (verify-installation.sh --post)" >> "$VALIDATION_REPORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"

    # Run with --post mode and strip colors
    bash "$SCRIPT_DIR/scripts/verify-installation.sh" --post 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
else
    echo "ERROR: verify-installation.sh not found!" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
fi

# 2. Critical features verification (verify-critical-features.sh)
if [ -f "$SCRIPT_DIR/scripts/verify-critical-features.sh" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "2. CRITICAL FEATURES VERIFICATION (verify-critical-features.sh)" >> "$VALIDATION_REPORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"

    # Run and strip colors
    bash "$SCRIPT_DIR/scripts/verify-critical-features.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
else
    echo "WARNING: verify-critical-features.sh not found!" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
fi

# 3. Extended validation (verify-extended-validation.sh)
if [ -f "$SCRIPT_DIR/scripts/verify-extended-validation.sh" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "3. EXTENDED VALIDATION (verify-extended-validation.sh)" >> "$VALIDATION_REPORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"

    # Run and strip colors
    bash "$SCRIPT_DIR/scripts/verify-extended-validation.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
else
    echo "WARNING: verify-extended-validation.sh not found!" >> "$VALIDATION_REPORT"
    echo "" >> "$VALIDATION_REPORT"
fi

echo -e "${GREEN}✓ Validation report created${NC}"

# ============================================
# REPORT 2: INSTALLED PACKAGES
# ============================================
echo -e "${YELLOW}[2/5] Generating installed packages report...${NC}"

PACKAGES_REPORT="$REPORT_DIR/installed-packages-report.txt"

cat > "$PACKAGES_REPORT" << 'EOFHEADER'
═══════════════════════════════════════════════════════════════════
  THIN-SERVER INSTALLED PACKAGES REPORT
═══════════════════════════════════════════════════════════════════

EOFHEADER

echo "Generated: $(date)" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

# System packages
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "SYSTEM PACKAGES (APT)" >> "$PACKAGES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

# Expected packages
EXPECTED_PACKAGES=(
    # Build tools
    "build-essential" "gcc" "g++" "make" "cmake" "pkg-config" "git"
    # Network tools
    "wget" "curl" "net-tools" "dnsutils" "iputils-ping" "iproute2"
    "openssh-server" "rsync" "ntpdate"
    # Python
    "python3" "python3-pip" "python3-venv" "python3-dev"
    # System tools
    "sqlite3" "cron" "logrotate" "vim" "htop"
    # X.org
    "xserver-xorg" "xserver-xorg-core" "xserver-xorg-input-evdev"
    "xserver-xorg-input-libinput"
    "xserver-xorg-video-vesa" "xserver-xorg-video-vmware"
    # Mesa/OpenGL
    "mesa-utils" "libgl1-mesa-dri" "libglx-mesa0"
    # Services
    "nginx" "tftpd-hpa" "p910nd" "alsa-utils"
    # Initramfs tools
    "busybox-static" "cpio" "gzip" "kmod"
)

echo "Checking expected packages:" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

INSTALLED_COUNT=0
MISSING_COUNT=0

for pkg in "${EXPECTED_PACKAGES[@]}"; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
        version=$(dpkg -l "$pkg" | grep "^ii" | awk '{print $3}')
        echo "✓ $pkg ($version)" >> "$PACKAGES_REPORT"
        ((INSTALLED_COUNT++))
    else
        echo "✗ $pkg - NOT INSTALLED" >> "$PACKAGES_REPORT"
        ((MISSING_COUNT++))
    fi
done

echo "" >> "$PACKAGES_REPORT"
echo "Summary: $INSTALLED_COUNT installed, $MISSING_COUNT missing" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

# Python packages
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "PYTHON PACKAGES (PIP3)" >> "$PACKAGES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

EXPECTED_PYTHON_PACKAGES=(
    "flask:flask"
    "flask-sqlalchemy:flask_sqlalchemy"
    "werkzeug:werkzeug"
    "pytz:pytz"
    "click:click"
    "cryptography:cryptography"
)

echo "Checking expected Python packages:" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

PY_INSTALLED=0
PY_MISSING=0

for pkg_entry in "${EXPECTED_PYTHON_PACKAGES[@]}"; do
    pkg_name="${pkg_entry%%:*}"
    import_name="${pkg_entry##*:}"

    if python3 -c "import $import_name" 2>/dev/null; then
        # Get version
        version=$(python3 -c "import $import_name; print(getattr($import_name, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
        echo "✓ $pkg_name ($version)" >> "$PACKAGES_REPORT"
        ((PY_INSTALLED++))
    else
        echo "✗ $pkg_name - NOT INSTALLED" >> "$PACKAGES_REPORT"
        ((PY_MISSING++))
    fi
done

echo "" >> "$PACKAGES_REPORT"
echo "Summary: $PY_INSTALLED installed, $PY_MISSING missing" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

# All installed packages (full list)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "ALL INSTALLED PACKAGES ($(dpkg -l 2>/dev/null | grep "^ii" | wc -l) total)" >> "$PACKAGES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

dpkg -l 2>/dev/null | grep "^ii" | awk '{printf "%-40s %s\n", $2, $3}' >> "$PACKAGES_REPORT" || echo "ERROR: dpkg command failed" >> "$PACKAGES_REPORT"

echo "" >> "$PACKAGES_REPORT"

# All Python packages
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "ALL PYTHON PACKAGES ($(pip3 list 2>/dev/null | tail -n +3 | wc -l) total)" >> "$PACKAGES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$PACKAGES_REPORT"
echo "" >> "$PACKAGES_REPORT"

pip3 list 2>/dev/null | tail -n +3 >> "$PACKAGES_REPORT"

echo -e "${GREEN}✓ Packages report created${NC}"

# ============================================
# REPORT 3: INITRAMFS CONTENTS
# ============================================
echo -e "${YELLOW}[3/5] Generating initramfs contents report...${NC}"

INITRAMFS_REPORT="$REPORT_DIR/initramfs-contents-report.txt"

cat > "$INITRAMFS_REPORT" << 'EOFHEADER'
═══════════════════════════════════════════════════════════════════
  THIN-SERVER INITRAMFS CONTENTS REPORT
═══════════════════════════════════════════════════════════════════

EOFHEADER

echo "Generated: $(date)" >> "$INITRAMFS_REPORT"
echo "" >> "$INITRAMFS_REPORT"

INITRAMFS_FILE="$WEB_ROOT/initrds/initrd-minimal.img"

if [ -f "$INITRAMFS_FILE" ]; then
    echo "Initramfs: $INITRAMFS_FILE" >> "$INITRAMFS_REPORT"

    # File size
    size=$(stat -c%s "$INITRAMFS_FILE" 2>/dev/null || stat -f%z "$INITRAMFS_FILE" 2>/dev/null)
    size_mb=$((size / 1024 / 1024))
    echo "Size: ${size_mb} MB" >> "$INITRAMFS_REPORT"
    echo "" >> "$INITRAMFS_REPORT"

    # Extract and analyze
    TEMP_DIR=$(mktemp -d)
    ORIGINAL_DIR="$(pwd)"

    # Determine decompression command from config
    DECOMPRESS_CMD="gunzip -c"
    if [ -n "$DECOMPRESSION_CMD" ]; then
        DECOMPRESS_CMD="$DECOMPRESSION_CMD"
    fi

    echo "Extracting initramfs..." >> "$INITRAMFS_REPORT"
    echo "Decompression: $DECOMPRESS_CMD" >> "$INITRAMFS_REPORT"
    cd "$TEMP_DIR" || { echo "✗ Failed to cd to temp dir" >> "$INITRAMFS_REPORT"; cd "$ORIGINAL_DIR"; return 1; }

    if $DECOMPRESS_CMD "$INITRAMFS_FILE" | cpio -idm 2>/dev/null; then
        echo "✓ Extraction successful" >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        # Critical binaries
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "CRITICAL BINARIES" >> "$INITRAMFS_REPORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        CRITICAL_BINS=(
            "usr/bin/xfreerdp:FreeRDP client"
            "usr/lib/xorg/Xorg:X.org server"
            "bin/busybox:BusyBox (core utilities)"
            "bin/ip:Network configuration"
            "usr/bin/ntpdate:NTP time sync"
            "sbin/modprobe:Kernel module loader"
            "sbin/udevd:Device manager"
        )

        for bin_spec in "${CRITICAL_BINS[@]}"; do
            bin_path="${bin_spec%%:*}"
            description="${bin_spec#*:}"

            #Check for ntpdate (can be in usr/bin or usr/sbin)
            if [ "$bin_path" = "usr/bin/ntpdate" ]; then
                if [ -f "$TEMP_DIR/$bin_path" ] || [ -L "$TEMP_DIR/$bin_path" ]; then
                    size=$(stat -c%s "$TEMP_DIR/$bin_path" 2>/dev/null || stat -f%z "$TEMP_DIR/$bin_path" 2>/dev/null || echo "0")
                    size_kb=$((size / 1024))
                    echo "✓ $bin_path (${size_kb} KB) - $description" >> "$INITRAMFS_REPORT"
                elif [ -f "$TEMP_DIR/usr/sbin/ntpdate" ]; then
                    size=$(stat -c%s "$TEMP_DIR/usr/sbin/ntpdate" 2>/dev/null || stat -f%z "$TEMP_DIR/usr/sbin/ntpdate" 2>/dev/null || echo "0")
                    size_kb=$((size / 1024))
                    echo "✓ usr/sbin/ntpdate (${size_kb} KB) - $description" >> "$INITRAMFS_REPORT"
                else
                    echo "✗ $bin_path - MISSING - $description" >> "$INITRAMFS_REPORT"
                fi
            elif [ -f "$TEMP_DIR/$bin_path" ]; then
                size=$(stat -c%s "$TEMP_DIR/$bin_path" 2>/dev/null || stat -f%z "$TEMP_DIR/$bin_path" 2>/dev/null)
                size_kb=$((size / 1024))
                echo "✓ $bin_path (${size_kb} KB) - $description" >> "$INITRAMFS_REPORT"
            else
                echo "✗ $bin_path - MISSING - $description" >> "$INITRAMFS_REPORT"
            fi
        done

        echo "" >> "$INITRAMFS_REPORT"

        # Kernel modules
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "KERNEL MODULES (DRIVERS)" >> "$INITRAMFS_REPORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        if [ -d "$TEMP_DIR/lib/modules" ]; then
            module_count=$(find "$TEMP_DIR/lib/modules" -name "*.ko" 2>/dev/null | wc -l)
            echo "Total modules: $module_count" >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"

            # Network drivers
            echo "Network drivers:" >> "$INITRAMFS_REPORT"
            find "$TEMP_DIR/lib/modules" -name "*.ko" -path "*/net/*" 2>/dev/null | while read mod; do
                basename "$mod"
            done | sort >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"

            # Graphics drivers
            echo "Graphics drivers (DRM):" >> "$INITRAMFS_REPORT"
            find "$TEMP_DIR/lib/modules" -name "*.ko" -path "*/drm/*" 2>/dev/null | while read mod; do
                basename "$mod"
            done | sort >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"

            # Input drivers
            echo "Input drivers:" >> "$INITRAMFS_REPORT"
            find "$TEMP_DIR/lib/modules" -name "*.ko" -path "*/input/*" 2>/dev/null | while read mod; do
                basename "$mod"
            done | sort >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"

            # USB drivers
            echo "USB drivers:" >> "$INITRAMFS_REPORT"
            find "$TEMP_DIR/lib/modules" -name "*.ko" -path "*/usb/*" 2>/dev/null | while read mod; do
                basename "$mod"
            done | sort >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"
        else
            echo "✗ No kernel modules found!" >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"
        fi

        # Libraries
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "SHARED LIBRARIES" >> "$INITRAMFS_REPORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        if [ -d "$TEMP_DIR/lib" ] || [ -d "$TEMP_DIR/usr/lib" ]; then
            lib_count=$(find "$TEMP_DIR/lib" "$TEMP_DIR/usr/lib" -name "*.so*" 2>/dev/null | wc -l)
            echo "Total libraries: $lib_count" >> "$INITRAMFS_REPORT"
            echo "" >> "$INITRAMFS_REPORT"

            echo "Critical libraries:" >> "$INITRAMFS_REPORT"
            for lib in libc.so libssl.so libcrypto.so libX11.so libGL.so libfreerdp; do
                found=$(find "$TEMP_DIR" -name "${lib}*" 2>/dev/null | head -1)
                if [ -n "$found" ]; then
                    rel_path=$(echo "$found" | sed "s|$TEMP_DIR/||")
                    echo "✓ $rel_path" >> "$INITRAMFS_REPORT"
                else
                    echo "✗ $lib - NOT FOUND" >> "$INITRAMFS_REPORT"
                fi
            done
            echo "" >> "$INITRAMFS_REPORT"
        fi

        # Directory structure
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "DIRECTORY STRUCTURE" >> "$INITRAMFS_REPORT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        du -sh "$TEMP_DIR"/* 2>/dev/null | sort -hr >> "$INITRAMFS_REPORT"
        echo "" >> "$INITRAMFS_REPORT"

        # Cleanup
        cd "$ORIGINAL_DIR" || cd /
        rm -rf "$TEMP_DIR"
    else
        echo "✗ Failed to extract initramfs" >> "$INITRAMFS_REPORT"
        cd "$ORIGINAL_DIR" || cd /
        rm -rf "$TEMP_DIR"
    fi
else
    echo "✗ Initramfs file not found: $INITRAMFS_FILE" >> "$INITRAMFS_REPORT"
fi

echo -e "${GREEN}✓ Initramfs contents report created${NC}"

# ============================================
# REPORT 4: SERVICES STATUS
# ============================================
echo -e "${YELLOW}[4/5] Generating services status report...${NC}"

SERVICES_REPORT="$REPORT_DIR/services-status-report.txt"

cat > "$SERVICES_REPORT" << 'EOFHEADER'
═══════════════════════════════════════════════════════════════════
  THIN-SERVER SERVICES STATUS REPORT
═══════════════════════════════════════════════════════════════════

EOFHEADER

echo "Generated: $(date)" >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

# Services to check
SERVICES=(
    "nginx:Nginx web server"
    "tftpd-hpa:TFTP server"
    "thinclient-manager:Flask application"
    "ssh:SSH server"
    "cron:Cron daemon"
)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "SYSTEMD SERVICES" >> "$SERVICES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

printf "%-30s %-10s %-10s %s\n" "SERVICE" "STATUS" "AUTOSTART" "DESCRIPTION" >> "$SERVICES_REPORT"
echo "────────────────────────────────────────────────────────────────────" >> "$SERVICES_REPORT"

for svc_spec in "${SERVICES[@]}"; do
    svc="${svc_spec%%:*}"
    desc="${svc_spec#*:}"

    # Check if running
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        status="✓ running"
    else
        status="✗ stopped"
    fi

    # Check if enabled
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        autostart="✓ enabled"
    else
        autostart="✗ disabled"
    fi

    printf "%-30s %-10s %-10s %s\n" "$svc" "$status" "$autostart" "$desc" >> "$SERVICES_REPORT"
done

echo "" >> "$SERVICES_REPORT"

# Listening ports
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "LISTENING PORTS" >> "$SERVICES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

echo "TCP ports:" >> "$SERVICES_REPORT"
ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4 " " $NF}' | sort >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

echo "UDP ports:" >> "$SERVICES_REPORT"
ss -ulnp 2>/dev/null | awk 'NR>1 {print $4 " " $NF}' | sort >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

# Service details
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "SERVICE DETAILS" >> "$SERVICES_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$SERVICES_REPORT"
echo "" >> "$SERVICES_REPORT"

for svc_spec in "${SERVICES[@]}"; do
    svc="${svc_spec%%:*}"

    echo "─────────────────────────────────────────" >> "$SERVICES_REPORT"
    echo "Service: $svc" >> "$SERVICES_REPORT"
    echo "─────────────────────────────────────────" >> "$SERVICES_REPORT"
    systemctl status "$svc" --no-pager 2>/dev/null >> "$SERVICES_REPORT" || echo "Not installed" >> "$SERVICES_REPORT"
    echo "" >> "$SERVICES_REPORT"
done

echo -e "${GREEN}✓ Services status report created${NC}"

# ============================================
# REPORT 5: SYSTEM CONFIGURATION
# ============================================
echo -e "${YELLOW}[5/5] Generating system configuration report...${NC}"

CONFIG_REPORT="$REPORT_DIR/system-configuration-report.txt"

cat > "$CONFIG_REPORT" << 'EOFHEADER'
═══════════════════════════════════════════════════════════════════
  THIN-SERVER SYSTEM CONFIGURATION REPORT
═══════════════════════════════════════════════════════════════════

EOFHEADER

echo "Generated: $(date)" >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

# Load config
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "THIN-SERVER CONFIGURATION (config.env)" >> "$CONFIG_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

if [ -f "/opt/thin-server/config.env" ]; then
    cat "/opt/thin-server/config.env" | grep -v "^#" | grep -v "^$" >> "$CONFIG_REPORT"
elif [ -f "$SCRIPT_DIR/config.env" ]; then
    cat "$SCRIPT_DIR/config.env" | grep -v "^#" | grep -v "^$" >> "$CONFIG_REPORT"
else
    echo "✗ config.env not found" >> "$CONFIG_REPORT"
fi

echo "" >> "$CONFIG_REPORT"

# Network configuration
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "NETWORK CONFIGURATION" >> "$CONFIG_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Network interfaces:" >> "$CONFIG_REPORT"
ip addr show 2>/dev/null >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Routing table:" >> "$CONFIG_REPORT"
ip route show 2>/dev/null >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "DNS configuration:" >> "$CONFIG_REPORT"
cat /etc/resolv.conf 2>/dev/null >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

# System info
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "SYSTEM INFORMATION" >> "$CONFIG_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "OS:" >> "$CONFIG_REPORT"
cat /etc/os-release >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Kernel:" >> "$CONFIG_REPORT"
uname -a >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Uptime:" >> "$CONFIG_REPORT"
uptime >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Memory:" >> "$CONFIG_REPORT"
free -h >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

echo "Disk usage:" >> "$CONFIG_REPORT"
df -h >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

# File locations
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "FILE LOCATIONS" >> "$CONFIG_REPORT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$CONFIG_REPORT"
echo "" >> "$CONFIG_REPORT"

CRITICAL_FILES=(
    "$TFTP_ROOT/efi64/bootx64.efi:iPXE bootloader"
    "$TFTP_ROOT/autoexec.ipxe:TFTP boot script"
    "$WEB_ROOT/boot.ipxe:HTTP boot script"
    "$WEB_ROOT/kernels/vmlinuz:Linux kernel"
    "$WEB_ROOT/initrds/initrd-minimal.img:Initramfs"
    "$APP_DIR/app.py:Flask application"
    "$DB_DIR/clients.db:SQLite database"
    "/etc/nginx/sites-enabled/thinclient:Nginx config"
    "/etc/systemd/system/thinclient-manager.service:Systemd service"
)

for file_spec in "${CRITICAL_FILES[@]}"; do
    file_path="${file_spec%%:*}"
    description="${file_spec#*:}"

    if [ -f "$file_path" ]; then
        size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null || echo "0")
        size_kb=$((size / 1024))
        echo "✓ $file_path (${size_kb} KB) - $description" >> "$CONFIG_REPORT"
    else
        echo "✗ $file_path - MISSING - $description" >> "$CONFIG_REPORT"
    fi
done

echo "" >> "$CONFIG_REPORT"

echo -e "${GREEN}✓ System configuration report created${NC}"

# ============================================
# SUMMARY
# ============================================
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  REPORT GENERATION COMPLETE${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Reports saved to:${NC} ${REPORT_DIR}"
echo ""
echo "Generated reports:"
echo "  1. deployment-validation-report.txt  - All verification checks"
echo "  2. installed-packages-report.txt     - Installed/missing packages"
echo "  3. initramfs-contents-report.txt     - Initramfs contents (drivers, libs)"
echo "  4. services-status-report.txt        - Services status, ports, autostart"
echo "  5. system-configuration-report.txt   - System configuration"
echo ""
echo -e "${YELLOW}To view reports:${NC}"
echo "  cd $REPORT_DIR"
echo "  cat deployment-validation-report.txt"
echo ""
echo -e "${YELLOW}To create archive:${NC}"
echo "  tar -czf thin-server-reports-$TIMESTAMP.tar.gz -C /opt/thin-server/reports $TIMESTAMP"
echo ""
