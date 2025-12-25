 #!/usr/bin/env bash
# Thin-Server Diagnostic Script: Initramfs Variant Selection Issues
# Diagnoses problems with client not loading correct initramfs variant

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "=============================================="
echo "Thin-Server Initramfs Variant Diagnostic"
echo "=============================================="
echo ""

# Check if running on Debian server
if [ ! -f /opt/thin-server/app.py ]; then
    echo -e "${RED}ERROR: This script must be run on the Thin-Server Debian server${NC}"
    echo "Path /opt/thin-server/app.py not found"
    exit 1
fi

echo -e "${GREEN}✓${NC} Running on Thin-Server server"
echo ""

echo -e "${BLUE}INFO: Thin-Server uses different initramfs variants for different GPUs:${NC}"
echo "  - initrd-intel.img     Intel GPUs (i915 driver)"
echo "  - initrd-amd.img       AMD GPUs (amdgpu driver)"
echo "  - initrd-vmware.img    VMware virtual GPUs"
echo "  - initrd-minimal.img   Universal fallback (fbdev/vesa, NO GPU acceleration)"
echo ""
echo "Clients auto-select variant based on MAC address or database setting."
echo ""

# 1. Check X.org packages
echo "=== Checking X.org packages ==="
PACKAGES=(
    "xserver-xorg-core"
    "xserver-xorg-video-fbdev"
    "xserver-xorg-video-vesa"
    "xserver-xorg-video-modesetting"
    "xserver-xorg-video-intel"
    "xserver-xorg-video-vmware"
    "xserver-xorg-input-libinput"
    "xserver-xorg-input-evdev"
)

MISSING_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if dpkg -l | grep -q "^ii.*$pkg"; then
        echo -e "${GREEN}✓${NC} $pkg installed"
    else
        echo -e "${RED}✗${NC} $pkg NOT installed"
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Missing packages detected!${NC}"
    echo "Install with: apt-get install ${MISSING_PACKAGES[*]}"
    echo ""
fi

# 2. Check X.org driver files
echo ""
echo "=== Checking X.org driver files ==="
DRIVER_PATH="/usr/lib/xorg/modules/drivers"

if [ ! -d "$DRIVER_PATH" ]; then
    echo -e "${RED}✗${NC} Driver directory missing: $DRIVER_PATH"
else
    echo -e "${GREEN}✓${NC} Driver directory exists: $DRIVER_PATH"
    echo ""
    echo "Available drivers:"

    for drv in fbdev vesa modesetting intel vmware amdgpu radeon; do
        if [ -f "$DRIVER_PATH/${drv}_drv.so" ]; then
            SIZE=$(stat -c%s "$DRIVER_PATH/${drv}_drv.so" 2>/dev/null || echo "unknown")
            MD5=$(md5sum "$DRIVER_PATH/${drv}_drv.so" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            echo -e "${GREEN}✓${NC} ${drv}_drv.so (size: $SIZE bytes, md5: ${MD5:0:8}...)"

            # Check if driver is corrupted by checking for "fbdeu" or similar
            if strings "$DRIVER_PATH/${drv}_drv.so" 2>/dev/null | grep -q "fbdeu"; then
                echo -e "${RED}  ⚠ WARNING: Driver contains corrupted string 'fbdeu'!${NC}"
            fi
        else
            echo -e "${YELLOW}✗${NC} ${drv}_drv.so not found"
        fi
    done
fi

# 3. Check ALL initramfs variants
echo ""
echo "=== Checking initramfs variants ==="
INITRAMFS_DIR="/var/www/thinclient/initrds"

if [ ! -d "$INITRAMFS_DIR" ]; then
    echo -e "${RED}✗${NC} Initramfs directory missing: $INITRAMFS_DIR"
else
    echo -e "${GREEN}✓${NC} Initramfs directory: $INITRAMFS_DIR"
    echo ""

    VARIANTS_FOUND=0
    VARIANTS_MISSING=()

    # Check all expected variants
    for variant_file in initrd-minimal.img initrd-intel.img initrd-amd.img initrd-vmware.img; do
        FULL_PATH="$INITRAMFS_DIR/$variant_file"
        if [ -f "$FULL_PATH" ]; then
            SIZE=$(stat -c%s "$FULL_PATH" 2>/dev/null || echo "unknown")
            SIZE_MB=$(echo "scale=1; $SIZE / 1024 / 1024" | bc 2>/dev/null || echo "?")
            DATE=$(stat -c%y "$FULL_PATH" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            echo -e "${GREEN}✓${NC} $variant_file"
            echo "    Size: ${SIZE_MB}MB, Date: $DATE"
            VARIANTS_FOUND=$((VARIANTS_FOUND + 1))
        else
            echo -e "${RED}✗${NC} $variant_file - NOT FOUND"
            VARIANTS_MISSING+=("$variant_file")
        fi
    done

    echo ""
    if [ $VARIANTS_FOUND -eq 0 ]; then
        echo -e "${RED}CRITICAL: NO initramfs variants found!${NC}"
        echo "Run: cd /opt/thin-server && ./modules/02-initramfs.sh && ./modules/build-initramfs-variants.sh"
    elif [ ${#VARIANTS_MISSING[@]} -gt 0 ]; then
        echo -e "${YELLOW}WARNING: Some variants missing: ${VARIANTS_MISSING[*]}${NC}"
        echo "Run: cd /opt/thin-server && ./modules/build-initramfs-variants.sh"
    else
        echo -e "${GREEN}✓ All initramfs variants present${NC}"
    fi
fi

# 4. Check which variant clients are using
echo ""
echo "=== Checking client variant assignments ==="
echo "Querying database for client configurations..."

python3 << 'PYEOF'
import sys
sys.path.insert(0, '/opt/thin-server')
try:
    import models
    model_classes = models.get_models()
    Client = model_classes['Client']

    clients = Client.query.filter_by(is_active=True).all()

    if not clients:
        print("No active clients in database")
    else:
        print(f"\nFound {len(clients)} active client(s):\n")
        for client in clients:
            driver = getattr(client, 'video_driver', 'auto') or 'auto'
            print(f"  MAC: {client.mac}")
            print(f"    Hostname: {client.hostname or 'N/A'}")
            print(f"    Video Driver: {driver}")
            print(f"    Last Boot: {client.last_boot or 'Never'}")
            print(f"    Status: {client.status or 'Unknown'}")

            # Determine which initramfs will be used
            if driver == 'auto':
                mac_prefix = client.mac[:8].upper() if client.mac else ''
                if mac_prefix in ['00:0C:29', '00:50:56', '00:05:69']:
                    expected = 'initrd-vmware.img'
                elif mac_prefix in ['08:00:27', '0A:00:27']:
                    expected = 'initrd-generic.img'
                elif mac_prefix.startswith(('00:14:22', '00:1A:A0', '00:1B:78', '00:21:5A', '00:21:CC', '54:EE:75')):
                    expected = 'initrd-intel.img'
                else:
                    expected = 'initrd-minimal.img (FALLBACK - may lack GPU drivers!)'
            elif driver == 'intel':
                expected = 'initrd-intel.img'
            elif driver == 'amd':
                expected = 'initrd-amd.img'
            elif driver == 'vmware':
                expected = 'initrd-vmware.img'
            elif driver in ['modesetting', 'generic']:
                expected = 'initrd-generic.img'
            else:
                expected = 'initrd-minimal.img'

            print(f"    Expected initramfs: {expected}")
            print()

except Exception as e:
    print(f"Error querying database: {e}")
    print("Make sure Flask app is properly configured")
PYEOF

# 4. Check TFTP server
echo ""
echo "=== Checking TFTP server ==="
if systemctl is-active --quiet tftpd-hpa; then
    echo -e "${GREEN}✓${NC} TFTP server is running"

    TFTP_ROOT=$(grep -oP 'TFTP_DIRECTORY="\K[^"]+' /etc/default/tftpd-hpa 2>/dev/null || echo "/var/lib/tftpboot")
    echo "  TFTP root: $TFTP_ROOT"
else
    echo -e "${RED}✗${NC} TFTP server is NOT running"
fi

# 5. Summary and recommendations
echo ""
echo "=============================================="
echo "DIAGNOSIS AND RECOMMENDATIONS"
echo "=============================================="
echo ""

echo -e "${BLUE}MOST COMMON ISSUE: Client loading wrong initramfs variant${NC}"
echo ""
echo "If your Intel PC shows 'no screens found' error:"
echo ""

echo -e "${GREEN}SOLUTION 1: Set correct video_driver in database (RECOMMENDED)${NC}"
echo "   Via Web Panel: http://<server-ip>/clients → Edit client → Video Driver: intel"
echo "   Via CLI:"
echo "     cd /opt/thin-server"
echo "     python3 cli.py client update <MAC-ADDRESS> --video-driver intel"
echo ""

echo -e "${GREEN}SOLUTION 2: Rebuild ALL initramfs variants${NC}"
echo "   cd /opt/thin-server"
echo "   ./modules/02-initramfs.sh"
echo "   ./modules/build-initramfs-variants.sh"
echo "   # Then reboot client"
echo ""

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo -e "${YELLOW}SOLUTION 3: Install missing X.org packages first${NC}"
    echo "   apt-get update && apt-get install ${MISSING_PACKAGES[*]}"
    echo "   # Then rebuild initramfs (see SOLUTION 2)"
    echo ""
fi

echo -e "${BLUE}OTHER DIAGNOSTICS:${NC}"
echo ""

echo "Check which initramfs client is actually loading:"
echo "   tail -f /var/log/thinclient/app.log | grep BOOT"
echo "   # Look for: 'Client <MAC> using initrd-*.img'"
echo ""

echo "Test boot configuration without rebooting client:"
echo "   curl http://localhost/api/boot/<MAC-ADDRESS>"
echo "   # Look for: 'initrd http://...initrds/initrd-XXX.img'"
echo ""

echo "Check client logs via SSH (if SSH enabled):"
echo "   ssh root@<client-ip>"
echo "   cat /var/log/Xorg.0.log"
echo "   lspci | grep -i vga     # Check GPU type"
echo "   ls -la /dev/dri/*       # Check GPU devices"
echo ""

echo "Diagnostic complete."
