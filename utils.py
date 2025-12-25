#!/usr/bin/env python3
"""
Thin-Server Utility Functions
Helper functions and validators
"""

import re
import os
import secrets
from functools import wraps
from flask import session, jsonify, request


# ============================================
# VALIDATION CONSTANTS & PATTERNS
# ============================================
MAC_REGEX = re.compile(r'^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$')
HOSTNAME_REGEX = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}[a-zA-Z0-9]$')
DOMAIN_REGEX = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9.-]{0,253}[a-zA-Z0-9]$')
USERNAME_REGEX = re.compile(r'^[a-zA-Z0-9._@-]{1,100}$')
VIDEO_DRIVERS = ['autodetect', 'intel', 'amd', 'vmware', 'universal']

# Resolution constraints
MIN_WIDTH = 640
MAX_WIDTH = 7680
MIN_HEIGHT = 480
MAX_HEIGHT = 4320


def login_required(f):
    """Decorator to require login for routes"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'admin_id' not in session:
            return jsonify({'error': 'Authentication required'}), 401
        return f(*args, **kwargs)
    return decorated_function


def get_client_ip():
    """
    Get real client IP address from request headers.
    When behind nginx proxy, use X-Real-IP or X-Forwarded-For headers.
    """
    # Try X-Real-IP first (set by nginx: proxy_set_header X-Real-IP $remote_addr;)
    real_ip = request.headers.get('X-Real-IP')
    if real_ip:
        return real_ip

    # Try X-Forwarded-For (comma-separated list, first is client)
    forwarded_for = request.headers.get('X-Forwarded-For')
    if forwarded_for:
        return forwarded_for.split(',')[0].strip()

    # Fallback to direct remote_addr
    return request.remote_addr


def log_audit(action, details=''):
    """Log audit event"""
    try:
        import models
        model_classes = models.get_models()
        AuditLog = model_classes['AuditLog']
        db = model_classes['db']
        
        if 'admin_username' not in session:
            return

        log_entry = AuditLog(
            admin_username=session.get('admin_username'),
            action=action,
            details=details,
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent', ''),
            timestamp=models.get_kyiv_time()
        )
        
        db.session.add(log_entry)
        db.session.commit()
    except Exception as e:
        print(f"Error logging audit: {e}")


def validate_mac(mac):
    """
    Validate and normalize MAC address

    Accepts formats:
    - 00:11:22:33:44:55
    - 00-11-22-33-44:55
    - 001122334455

    Returns normalized MAC (UPPERCASE with colons) or None
    """
    if not mac:
        return None

    # Remove whitespace
    mac = mac.strip()

    # Remove all separators and convert to uppercase
    clean = re.sub(r'[:-]', '', mac).upper()

    # Check if valid hex and length
    if not re.match(r'^[0-9A-F]{12}$', clean):
        return None

    # Reject reserved/invalid MAC addresses
    INVALID_MACS = [
        '000000000000',  # Null MAC
        'FFFFFFFFFFFF',  # Broadcast MAC
    ]

    if clean in INVALID_MACS:
        return None

    # Format with colons (uppercase)
    return ':'.join(clean[i:i+2] for i in range(0, 12, 2))


def validate_ip(ip):
    """Validate IPv4 address"""
    if not ip:
        return False
    
    pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
    if not re.match(pattern, ip):
        return False
    
    parts = ip.split('.')
    return all(0 <= int(part) <= 255 for part in parts)


def check_password_strength(password):
    """
    Check password strength
    
    Returns:
        (bool, str): (is_strong, message)
    """
    if not password:
        return False, "Password cannot be empty"
    
    if len(password) < 8:
        return False, "Password must be at least 8 characters long"
    
    if not re.search(r'[a-z]', password):
        return False, "Password must contain lowercase letters"
    
    if not re.search(r'[A-Z]', password):
        return False, "Password must contain uppercase letters"
    
    if not re.search(r'\d', password):
        return False, "Password must contain numbers"
    
    return True, "Password is strong"


def generate_random_password(length=16):
    """Generate a random secure password"""
    alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*'
    return ''.join(secrets.choice(alphabet) for _ in range(length))


# ============================================
# NEW VALIDATION FUNCTIONS - SECURITY UPDATE
# ============================================

def validate_resolution(width, height):
    """
    Validate screen resolution values

    Args:
        width: Screen width in pixels
        height: Screen height in pixels

    Returns:
        (bool, str): (is_valid, error_message)
    """
    try:
        width = int(width)
        height = int(height)
    except (ValueError, TypeError):
        return False, "Resolution must be integers"

    if not (MIN_WIDTH <= width <= MAX_WIDTH):
        return False, f"Width must be between {MIN_WIDTH} and {MAX_WIDTH}"

    if not (MIN_HEIGHT <= height <= MAX_HEIGHT):
        return False, f"Height must be between {MIN_HEIGHT} and {MAX_HEIGHT}"

    return True, ""


def validate_hostname(hostname):
    """
    Validate hostname according to RFC 1123

    Args:
        hostname: Hostname string

    Returns:
        (bool, str): (is_valid, error_message)
    """
    if not hostname:
        return True, ""  # Hostname is optional

    if len(hostname) > 63:
        return False, "Hostname too long (max 63 chars)"

    if not HOSTNAME_REGEX.match(hostname):
        return False, "Invalid hostname format (alphanumeric and hyphens only)"

    return True, ""


def validate_domain(domain):
    """
    Validate domain name

    Args:
        domain: Domain name string

    Returns:
        (bool, str): (is_valid, error_message)
    """
    if not domain:
        return True, ""  # Domain is optional

    if len(domain) > 253:
        return False, "Domain too long (max 253 chars)"

    if not DOMAIN_REGEX.match(domain):
        return False, "Invalid domain format"

    return True, ""


def validate_username(username):
    """
    Validate username for RDP connection

    Args:
        username: Username string

    Returns:
        (bool, str): (is_valid, error_message)
    """
    if not username:
        return True, ""  # Username is optional (manual login)

    if len(username) > 100:
        return False, "Username too long (max 100 chars)"

    if not USERNAME_REGEX.match(username):
        return False, "Invalid username format (alphanumeric, dots, underscores, @ and hyphens only)"

    return True, ""


def validate_video_driver(driver):
    """
    Validate video driver selection

    Args:
        driver: Video driver name

    Returns:
        (bool, str): (is_valid, error_message)
    """
    if not driver:
        driver = 'auto'

    if driver not in VIDEO_DRIVERS:
        return False, f"Invalid video driver. Must be one of: {', '.join(VIDEO_DRIVERS)}"

    return True, ""


def validate_client_params(client_data):
    """
    Comprehensive validation of all client parameters

    Args:
        client_data: Dict with client parameters

    Returns:
        (bool, str): (is_valid, error_message)

    Raises:
        ValueError: If validation fails
    """
    errors = []

    # Validate MAC (required)
    if 'mac' in client_data:
        normalized_mac = validate_mac(client_data['mac'])
        if not normalized_mac:
            errors.append("Invalid MAC address format")
        else:
            client_data['mac'] = normalized_mac  # Update with normalized version
    else:
        errors.append("MAC address is required")

    # Validate hostname (optional)
    if 'hostname' in client_data and client_data['hostname']:
        valid, msg = validate_hostname(client_data['hostname'])
        if not valid:
            errors.append(msg)

    # Validate resolution
    if 'rdp_width' in client_data and 'rdp_height' in client_data:
        valid, msg = validate_resolution(client_data['rdp_width'], client_data['rdp_height'])
        if not valid:
            errors.append(msg)

    # Validate RDP domain (optional)
    if 'rdp_domain' in client_data and client_data['rdp_domain']:
        valid, msg = validate_domain(client_data['rdp_domain'])
        if not valid:
            errors.append(msg)

    # Validate RDP username (optional)
    if 'rdp_username' in client_data and client_data['rdp_username']:
        valid, msg = validate_username(client_data['rdp_username'])
        if not valid:
            errors.append(msg)

    # Validate video driver
    if 'video_driver' in client_data:
        valid, msg = validate_video_driver(client_data['video_driver'])
        if not valid:
            errors.append(msg)

    # Validate RDP server (should be hostname or IP)
    if 'rdp_server' in client_data and client_data['rdp_server']:
        server = client_data['rdp_server']
        # Try as domain first, then as IP
        valid_domain, _ = validate_domain(server)
        valid_ip = validate_ip(server)
        if not valid_domain and not valid_ip:
            errors.append("Invalid RDP server (must be valid hostname or IP)")

    if errors:
        return False, "; ".join(errors)

    return True, ""


def generate_boot_script(client, config, boot_token=None):
    """
    Generate iPXE boot script for client

    Args:
        client: Client object from database
        config: Config object with server settings
        boot_token: One-time boot token for secure credential retrieval

    Returns:
        iPXE script as string
    """
    # Build kernel parameters
    # init=/init tells kernel to use /init from initramfs as init process
    # rw = mount root filesystem as read-write
    params = f"init=/init rw "
    params += f"serverip={config.SERVER_IP} "
    params += f"rdserver={client.rdp_server or config.RDS_SERVER} "
    params += f"ntpserver={config.NTP_SERVER}"

    # RDP credentials - use boot token if available, otherwise fall back to direct credentials
    if client.rdp_domain:
        params += f" rdpdomain={client.rdp_domain}"
    if client.rdp_username:
        params += f" rdpuser={client.rdp_username}"

    # Pass boot token instead of password
    if boot_token:
        params += f" boottoken={boot_token}"
    elif client.rdp_password:
        # Fallback for legacy support (will be removed in future)
        params += f" rdppass={client.rdp_password}"

    # Resolution - support multiple formats
    resolution = None
    if hasattr(client, 'resolution') and client.resolution:
        resolution = client.resolution
    elif hasattr(client, 'rdp_width') and hasattr(client, 'rdp_height'):
        if client.rdp_width and client.rdp_height:
            resolution = f"{client.rdp_width}x{client.rdp_height}"

    if resolution and resolution != 'fullscreen':
        params += f" resolution={resolution}"
    else:
        params += " resolution=fullscreen"

    # ============================================
    # PERIPHERAL PARAMETERS - ALL DEVICES
    # ============================================

    # Sound - ALSA/PulseAudio
    if hasattr(client, 'sound_enabled'):
        params += f" sound={'yes' if client.sound_enabled else 'no'}"
    else:
        params += " sound=yes"  # Default

    # Printer redirection (RDP printer)
    if hasattr(client, 'printer_enabled'):
        params += f" printer={'yes' if client.printer_enabled else 'no'}"
    else:
        params += " printer=no"  # Default

    # USB redirection
    if hasattr(client, 'usb_redirect'):
        params += f" usb={'yes' if client.usb_redirect else 'no'}"
    else:
        params += " usb=no"  # Default

    # Clipboard sharing
    if hasattr(client, 'clipboard_enabled'):
        params += f" clipboard={'yes' if client.clipboard_enabled else 'no'}"
    else:
        params += " clipboard=yes"  # Default

    # Drive/folder redirection
    if hasattr(client, 'drives_redirect'):
        params += f" drives={'yes' if client.drives_redirect else 'no'}"
    else:
        params += " drives=no"  # Default

    # Compression
    if hasattr(client, 'compression_enabled'):
        params += f" compression={'yes' if client.compression_enabled else 'no'}"
    else:
        params += " compression=yes"  # Default

    # Multi-monitor
    if hasattr(client, 'multimon_enabled'):
        params += f" multimon={'yes' if client.multimon_enabled else 'no'}"
    else:
        params += " multimon=no"  # Default

    # Print Server (p910nd on TCP 9100) - SEPARATE from RDP printer!
    if hasattr(client, 'print_server_enabled'):
        params += f" printserver={'yes' if client.print_server_enabled else 'no'}"
    else:
        params += " printserver=no"  # Default

    # Video Driver (for X.org)
    if hasattr(client, 'video_driver') and client.video_driver:
        if client.video_driver not in ['auto', 'modesetting', None, '']:
            params += f" videodriver={client.video_driver}"

    # SSH diagnostics
    if hasattr(client, 'ssh_enabled') and client.ssh_enabled:
        ssh_password = getattr(client, 'ssh_password', 'thinclient2025')
        params += f" sshpass={ssh_password}"

    # Debug/verbose mode
    if hasattr(client, 'debug_mode') and client.debug_mode:
        params += " verbose=yes"

    # ============================================
    # ВИБІР ПРАВИЛЬНОГО INITRAMFS
    # ============================================
    initrd_file = "initrd-minimal.img"  # Default fallback

    # Мапінг драйверів на файли initramfs
    driver_map = {
        'intel': 'initrd-intel.img',
        'amd': 'initrd-amd.img',
        'nvidia': 'initrd-nvidia.img',
        'vmware': 'initrd-vmware.img',
        'modesetting': 'initrd-generic.img',
        'generic': 'initrd-generic.img'
    }

    if hasattr(client, 'video_driver') and client.video_driver:
        if client.video_driver == 'auto':
            # Auto-detect based on MAC prefix
            mac_prefix = client.mac[:8].upper() if client.mac else ''

            # VMware MACs
            if mac_prefix in ['00:0C:29', '00:50:56', '00:05:69']:
                initrd_file = 'initrd-vmware.img'
                print(f"[BOOT] Auto-detected VMware for {client.mac}")
            # VirtualBox MACs
            elif mac_prefix in ['08:00:27', '0A:00:27']:
                initrd_file = 'initrd-generic.img'
                print(f"[BOOT] Auto-detected VirtualBox for {client.mac}")
            # Dell (often Intel)
            elif mac_prefix.startswith('00:14:22') or mac_prefix.startswith('00:1A:A0'):
                initrd_file = 'initrd-intel.img'
                print(f"[BOOT] Auto-detected Dell (Intel) for {client.mac}")
            # HP (mixed, default to Intel)
            elif mac_prefix.startswith('00:1B:78') or mac_prefix.startswith('00:21:5A'):
                initrd_file = 'initrd-intel.img'
                print(f"[BOOT] Auto-detected HP (Intel) for {client.mac}")
            # Lenovo (often Intel)
            elif mac_prefix.startswith('00:21:CC') or mac_prefix.startswith('54:EE:75'):
                initrd_file = 'initrd-intel.img'
                print(f"[BOOT] Auto-detected Lenovo (Intel) for {client.mac}")
            else:
                # Default to minimal (smallest)
                initrd_file = 'initrd-minimal.img'
                print(f"[BOOT] Using minimal initramfs for unknown MAC {client.mac}")
        else:
            # Use specific driver mapping
            initrd_file = driver_map.get(client.video_driver, 'initrd-minimal.img')
            print(f"[BOOT] Using {initrd_file} for driver {client.video_driver}")

    # Перевірити чи файл існує
    initrd_path = f"/var/www/thinclient/initrds/{initrd_file}"
    if not os.path.exists(initrd_path):
        print(f"[BOOT] WARNING: Initramfs {initrd_file} not found at {initrd_path}, using fallback")
        initrd_file = "initrd-minimal.img"

        # Якщо і fallback немає - критична помилка
        fallback_path = f"/var/www/thinclient/initrds/{initrd_file}"
        if not os.path.exists(fallback_path):
            print(f"[ERROR] CRITICAL: No initramfs files found at /var/www/thinclient/initrds/")
            raise FileNotFoundError("No initramfs files available")

    # Логування для діагностики
    print(f"[BOOT] Client {client.mac} using {initrd_file} (driver: {getattr(client, 'video_driver', 'none')})")

    # Generate iPXE script
    script = "#!ipxe\n\n"
    script += "echo ========================================\n"
    script += f"echo Thin-Server ThinClient v{config.VERSION}\n"
    script += f"echo MAC: {client.mac}\n"
    script += f"echo Hostname: {client.hostname or 'N/A'}\n"
    script += f"echo Location: {client.location or 'Unknown'}\n"
    script += f"echo RDS Server: {client.rdp_server or config.RDS_SERVER}\n"
    script += f"echo Using initramfs: {initrd_file}\n"
    script += "echo ========================================\n\n"
    script += f"kernel http://{config.SERVER_IP}/kernels/vmlinuz {params}\n"
    script += f"initrd http://{config.SERVER_IP}/initrds/{initrd_file}\n"
    script += "boot\n"

    return script


def paginate_query(query, page=1, per_page=20):
    """
    Paginate SQLAlchemy query
    
    Returns:
        (items, total, has_prev, has_next)
    """
    total = query.count()
    items = query.offset((page - 1) * per_page).limit(per_page).all()
    
    has_prev = page > 1
    has_next = page * per_page < total
    
    return items, total, has_prev, has_next


def get_system_stats():
    """Get system statistics"""
    try:
        import models
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']
        Admin = model_classes['Admin']
        AuditLog = model_classes['AuditLog']
        
        stats = {
            'total_clients': Client.query.filter_by(is_active=True).count(),
            'online_clients': Client.query.filter_by(is_active=True, status='online').count(),
            'total_boots': Client.query.with_entities(
                models.db.func.sum(Client.boot_count)
            ).scalar() or 0,
            'total_logs': ClientLog.query.count(),
            'total_admins': Admin.query.filter_by(is_active=True).count(),
            'total_audit_logs': AuditLog.query.count()
        }
        
        return stats
    except Exception as e:
        print(f"Error getting system stats: {e}")
        return {}


def format_bytes(bytes_value):
    """Format bytes to human readable"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_value < 1024.0:
            return f"{bytes_value:.2f} {unit}"
        bytes_value /= 1024.0
    return f"{bytes_value:.2f} PB"


def format_uptime(seconds):
    """Format seconds to human readable uptime"""
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    
    parts = []
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0:
        parts.append(f"{minutes}m")
    
    return ' '.join(parts) if parts else '0m'