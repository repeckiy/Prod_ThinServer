#!/usr/bin/env python3
"""
Thin-Server Boot Configuration API
iPXE boot script generation and client registration
"""

from flask import request, current_app, jsonify
from . import api
import models
from utils import generate_boot_script, validate_mac, get_client_ip, log_audit
from config import Config
from functools import wraps
from datetime import datetime, timedelta

# Simple in-memory rate limiting (100 requests per minute per IP)
# Format: {ip: [(timestamp1, timestamp2, ...)]}
_boot_rate_limit_cache = {}
_BOOT_RATE_LIMIT = 100  # requests per minute
_BOOT_RATE_WINDOW = 60  # seconds


def boot_rate_limit(f):
    """Simple rate limiter for boot endpoint: 100 requests per minute per IP"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        # Get client IP
        client_ip = request.headers.get('X-Real-IP') or request.headers.get('X-Forwarded-For', '').split(',')[0].strip() or request.remote_addr

        now = datetime.now()
        cutoff = now - timedelta(seconds=_BOOT_RATE_WINDOW)

        # Clean old entries for this IP
        if client_ip in _boot_rate_limit_cache:
            _boot_rate_limit_cache[client_ip] = [
                ts for ts in _boot_rate_limit_cache[client_ip] if ts > cutoff
            ]
        else:
            _boot_rate_limit_cache[client_ip] = []

        # Check rate limit
        if len(_boot_rate_limit_cache[client_ip]) >= _BOOT_RATE_LIMIT:
            return f"# Rate limit exceeded: {_BOOT_RATE_LIMIT} requests per minute\n# Please wait before retrying\n", 429, {'Content-Type': 'text/plain'}

        # Add current request
        _boot_rate_limit_cache[client_ip].append(now)

        return f(*args, **kwargs)
    return decorated_function


@api.route('/boot/<mac>')
@boot_rate_limit
def boot_config(mac):
    """
    Generate boot configuration for thin client

    GET /api/boot/<mac>

    No authentication required (clients can't authenticate)
    Rate limit: 100 requests per minute per IP (if Flask-Limiter installed)
    """
    try:
        # Get models
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        # Validate and normalize MAC
        mac = validate_mac(mac)
        if not mac:
            return "# Invalid MAC address format\n", 400, {'Content-Type': 'text/plain'}

        client = Client.query.filter_by(mac=mac).first()

        # Get client IP once (used for registration and boot logging)
        client_ip = get_client_ip()

        # Auto-register if not exists
        is_new_client = False
        if not client:
            is_new_client = True
            current_app.logger.info(f"Auto-registering new client: {mac} from {client_ip}")
            try:
                client = Client(
                    mac=mac,
                    rdp_server=Config.RDS_SERVER,
                    hostname=f'tc-{mac.replace(":", "")[-6:]}',
                    last_ip=client_ip,
                    last_seen=models.get_kyiv_time()
                )
                db.session.add(client)
                db.session.flush()  # Get client.id before creating log

                # Create log entry for auto-registration
                ClientLog = model_classes['ClientLog']
                registration_log = ClientLog(
                    client_id=client.id,
                    event_type='INFO',
                    category='registration',
                    details=f'Auto-registered new thin client from IP {client_ip}. Hostname: {client.hostname}, RDS: {client.rdp_server}',
                    ip_address=client_ip
                )
                db.session.add(registration_log)
                current_app.logger.info(f"Created registration log for {mac}")
            except Exception as e:
                current_app.logger.error(f"Failed to auto-register client {mac}: {e}", exc_info=True)
                db.session.rollback()
                return f"# Error: Failed to register client\n", 500, {'Content-Type': 'text/plain'}

        # Update boot statistics and generate boot token
        try:
            client.boot_count = (client.boot_count or 0) + 1
            is_first_boot = (client.boot_count == 1)
            client.last_boot = models.get_kyiv_time()
            client.last_ip = client_ip
            client.last_seen = models.get_kyiv_time()
            client.status = 'booting'

            # Generate one-time boot token for secure credential retrieval
            boot_token = client.generate_boot_token()

            # Create log entry for boot event
            ClientLog = model_classes['ClientLog']
            if is_first_boot and not is_new_client:
                # First boot of existing client
                boot_log = ClientLog(
                    client_id=client.id,
                    event_type='INFO',
                    category='boot',
                    details=f'First boot from IP {client_ip}. RDS: {client.rdp_server}',
                    ip_address=client_ip
                )
            elif is_new_client:
                # First boot of auto-registered client (already logged registration above)
                boot_log = ClientLog(
                    client_id=client.id,
                    event_type='INFO',
                    category='boot',
                    details=f'Boot #{client.boot_count} from IP {client_ip}. New client first boot.',
                    ip_address=client_ip
                )
            else:
                # Regular boot
                boot_log = ClientLog(
                    client_id=client.id,
                    event_type='INFO',
                    category='boot',
                    details=f'Boot #{client.boot_count} from IP {client_ip}',
                    ip_address=client_ip
                )
            db.session.add(boot_log)

            db.session.commit()
            current_app.logger.info(f"Client {mac} boot #{client.boot_count} from {client_ip}, token generated")
        except Exception as e:
            current_app.logger.error(f"Failed to update client boot info: {e}", exc_info=True)
            db.session.rollback()
            # Continue anyway - boot script generation doesn't require database update
            boot_token = None

        # Generate boot script with token instead of password
        try:
            script = generate_boot_script(client, Config, boot_token=boot_token)
            return script, 200, {'Content-Type': 'text/plain'}
        except Exception as e:
            current_app.logger.error(f"Failed to generate boot script for {mac}: {e}", exc_info=True)
            return f"# Error: Failed to generate boot configuration\n", 500, {'Content-Type': 'text/plain'}

    except Exception as e:
        current_app.logger.error(f"Unexpected error in boot_config for {mac}: {e}", exc_info=True)
        return f"# Error: Internal server error\n", 500, {'Content-Type': 'text/plain'}


@api.route('/boot/<mac>/test')
@boot_rate_limit
def boot_config_test(mac):
    """Test boot configuration without updating statistics (rate limited)"""

    try:
        # Get models
        model_classes = models.get_models()
        Client = model_classes['Client']

        mac = validate_mac(mac)
        if not mac:
            return "# Invalid MAC address format\n", 400, {'Content-Type': 'text/plain'}

        client = Client.query.filter_by(mac=mac).first()

        if not client:
            return "# Client not registered\n", 404, {'Content-Type': 'text/plain'}

        # Generate boot script
        try:
            script = generate_boot_script(client, Config)
            return script, 200, {'Content-Type': 'text/plain'}
        except Exception as e:
            current_app.logger.error(f"Failed to generate test boot script for {mac}: {e}", exc_info=True)
            return f"# Error: Failed to generate boot configuration\n", 500, {'Content-Type': 'text/plain'}

    except Exception as e:
        current_app.logger.error(f"Unexpected error in boot_config_test for {mac}: {e}", exc_info=True)
        return f"# Error: Internal server error\n", 500, {'Content-Type': 'text/plain'}


@api.route('/boot/credentials/<token>')
def get_boot_credentials(token):
    """
    Retrieve RDP credentials using boot token

    GET /api/boot/credentials/<token>

    Returns JSON with credentials if token is valid
    Token is consumed after successful retrieval
    """
    from flask import jsonify

    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        # Find client by boot token
        client = Client.query.filter_by(boot_token=token).first()

        if not client:
            current_app.logger.warning(f"Invalid boot token requested: {token[:8]}...")
            # Log security event to AuditLog
            log_audit(
                action='INVALID_BOOT_TOKEN',
                details=f'Invalid boot token requested: {token[:8]}... from IP {get_client_ip()}',
                admin_username='SYSTEM'
            )
            return jsonify({'error': 'Invalid token'}), 404

        # Validate token (check expiration)
        try:
            is_valid = client.validate_boot_token(token)
            if not is_valid:
                from datetime import datetime
                import pytz
                KYIV_TZ = pytz.timezone('Europe/Kyiv')
                now = datetime.now(KYIV_TZ)
                expires = client.boot_token_expires
                current_app.logger.warning(f"Boot token validation failed for client {client.mac}. Current: {now}, Expires: {expires}")
                # Log security event to AuditLog
                log_audit(
                    action='EXPIRED_BOOT_TOKEN',
                    details=f'Expired boot token for client {client.mac} from IP {get_client_ip()}. Expired at: {expires}',
                    admin_username='SYSTEM'
                )
                client.consume_boot_token()  # Clean up expired token
                db.session.commit()
                return jsonify({'error': 'Token expired'}), 403
        except Exception as val_err:
            current_app.logger.error(f"Token validation error for client {client.mac}: {val_err}", exc_info=True)
            return jsonify({'error': 'Token validation failed'}), 500

        # Return credentials (with safe password decryption)
        try:
            rdp_password = client.rdp_password or ''
        except Exception as pwd_err:
            current_app.logger.error(f"Failed to decrypt password for client {client.mac}: {pwd_err}", exc_info=True)
            rdp_password = ''  # Fallback to empty password if decryption fails

        credentials = {
            'rdp_server': client.rdp_server or Config.RDS_SERVER,
            'rdp_domain': client.rdp_domain or '',
            'rdp_username': client.rdp_username or '',
            'rdp_password': rdp_password
        }

        # Consume token (one-time use)
        client.consume_boot_token()
        db.session.commit()

        current_app.logger.info(f"Credentials retrieved for {client.mac} using token")

        return jsonify(credentials), 200

    except Exception as e:
        current_app.logger.error(f"Failed to retrieve boot credentials: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error'}), 500