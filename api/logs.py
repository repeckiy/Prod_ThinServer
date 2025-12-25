#!/usr/bin/env python3
"""
Thin-Server Logging API
Client and system log management
"""

from flask import request, jsonify, current_app
from datetime import timedelta, datetime
from functools import wraps
from . import api
import models
from utils import login_required, log_audit, get_client_ip
import os
import subprocess
import re


# ============================================
# SECURITY LIMITS
# ============================================
MAX_LOG_MESSAGE_SIZE = 8192  # 8KB max per log message
MAX_MAC_LENGTH = 17  # XX:XX:XX:XX:XX:XX

# ============================================
# LOG CATEGORIES
# ============================================
LOG_CATEGORIES = {
    'xserver': ['X server', 'Xorg', 'X11', 'GLX', 'DRI', 'keyboard', 'mouse', 'display', 'screen', 'video', 'input device', 'input'],
    'freerdp': ['RDP', 'FreeRDP', 'xfreerdp', 'disconnected', 'connection', 'session'],
    'network': ['Network', 'DHCP', 'IP', 'ethernet', 'eth0', 'DNS', 'interface'],
    'ntp': ['Time sync', 'NTP', 'rdate', 'ntpd', 'ntpdate', 'clock'],
    'boot': ['booting', 'initramfs', 'kernel', 'mount', 'Loading modules', 'udev', 'starting'],
    'print': ['Print server', 'p910nd', 'printer', 'lp0'],
    'system': ['system', 'error', 'warning', 'failed', 'module', 'driver', 'ssh', 'dropbear', 'audio', 'alsa', 'sound', 'snd']
}

def classify_log(message):
    """Класифікувати лог за категорією"""
    if not message:
        return 'other'
    
    message_lower = message.lower()
    
    for category, keywords in LOG_CATEGORIES.items():
        for keyword in keywords:
            if keyword.lower() in message_lower:
                return category
    
    return 'other'


# ============================================
# RATE LIMITING FOR CLIENT LOGS
# ============================================
# Simple in-memory rate limiting (60 requests per minute per MAC)
_client_log_rate_limit_cache = {}
_CLIENT_LOG_RATE_LIMIT = 60  # requests per minute per MAC
_CLIENT_LOG_RATE_WINDOW = 60  # seconds


def client_log_rate_limit(f):
    """Rate limiter for client log endpoints: 60 requests per minute per MAC"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        # Get MAC address from form data or request body
        mac = request.form.get('mac', '').upper()

        # For batch endpoint, try to get MAC from first line of body
        if not mac and request.data:
            try:
                first_line = request.data.decode('utf-8', errors='ignore').split('\n')[0]
                parts = first_line.split('|')
                if len(parts) >= 4:
                    mac = parts[3].upper().strip()
            except:
                pass

        # Fallback to IP if no MAC
        rate_key = mac if mac else f"IP:{request.remote_addr}"

        now = datetime.now()
        cutoff = now - timedelta(seconds=_CLIENT_LOG_RATE_WINDOW)

        # Clean old entries for this key
        if rate_key in _client_log_rate_limit_cache:
            _client_log_rate_limit_cache[rate_key] = [
                ts for ts in _client_log_rate_limit_cache[rate_key] if ts > cutoff
            ]
        else:
            _client_log_rate_limit_cache[rate_key] = []

        # Check rate limit
        if len(_client_log_rate_limit_cache[rate_key]) >= _CLIENT_LOG_RATE_LIMIT:
            current_app.logger.warning(f"Rate limit exceeded for {rate_key}: {_CLIENT_LOG_RATE_LIMIT}/min")
            # Log security event to AuditLog
            log_audit(
                action='RATE_LIMIT_EXCEEDED',
                details=f'Client log rate limit exceeded for {rate_key}: {_CLIENT_LOG_RATE_LIMIT} requests/min from IP {request.remote_addr}',
                admin_username='SYSTEM'
            )
            return '', 429  # Too Many Requests

        # Add current request
        _client_log_rate_limit_cache[rate_key].append(now)

        return f(*args, **kwargs)
    return decorated_function


# ============================================
# CLIENT LOG RECEPTION
# ============================================
@api.route('/client-log', methods=['POST'])
@client_log_rate_limit
def client_log():
    """Receive logs from thin clients (no auth)

    Rate limit: 60 requests per minute per MAC address
    """
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']
        db = model_classes['db']
        
        mac = request.form.get('mac', '').upper()
        level = request.form.get('level', 'INFO').upper()
        message = request.form.get('message', '')
        source = request.form.get('source', 'boot')

        # Validate inputs
        if not mac or not message:
            return '', 400

        # Security: Enforce size limits
        if len(mac) > MAX_MAC_LENGTH:
            return '', 400

        if len(message) > MAX_LOG_MESSAGE_SIZE:
            # Truncate message instead of rejecting
            message = message[:MAX_LOG_MESSAGE_SIZE] + '... [TRUNCATED]'

        # Validate level
        if level not in ['DEBUG', 'INFO', 'WARN', 'ERROR', 'CRITICAL']:
            level = 'INFO'
        
        # Find or create client
        client = Client.query.filter_by(mac=mac).first()

        client_ip = get_client_ip()
        is_new_client = False

        if not client:
            is_new_client = True
            client = Client(
                mac=mac,
                hostname=f"TC-{mac[-8:].replace(':', '')}",
                is_active=True,
                last_ip=client_ip,
                last_seen=models.get_kyiv_time()
            )
            db.session.add(client)
            db.session.flush()

            # Create log entry for auto-registration via log submission
            registration_log = ClientLog(
                client_id=client.id,
                event_type='INFO',
                category='registration',
                details=f'Auto-registered via log submission from IP {client_ip}. Hostname: {client.hostname}',
                ip_address=client_ip
            )
            db.session.add(registration_log)
            current_app.logger.info(f"Auto-registered client {mac} via log submission from {client_ip}")
        
        # Format message
        formatted_message = f"[{source}] {message}" if source else message
        
        # Classify
        category = classify_log(formatted_message)

        # Log to console
        current_app.logger.info(f"Client log: MAC={mac} {level} [{category}]: {formatted_message}")

        log_entry = ClientLog(
            client_id=client.id,
            event_type=level,
            details=formatted_message,
            category=category,
            ip_address=client_ip,
            timestamp=models.get_kyiv_time()
        )

        client.last_ip = client_ip
        client.last_seen = models.get_kyiv_time()

        # ============================================
        # PARSE SPECIFIC LOG TYPES FOR METRICS
        # ============================================
        import re

        # Parse network drivers count
        if 'Network drivers: loaded=' in message or 'loaded=' in message:
            match = re.search(r'loaded=(\d+)', message)
            if match:
                client.network_drivers_loaded = int(match.group(1))
                current_app.logger.info(f"{mac} network drivers loaded: {client.network_drivers_loaded}")

        # Parse RDP connection parameters
        elif 'RDP connecting with:' in message or 'xfreerdp' in message.lower():
            # Parse peripheral status from RDP connection string
            if 'sound=yes' in message.lower():
                client.last_sound_status = True
            elif 'sound=no' in message.lower():
                client.last_sound_status = False

            if 'printer=yes' in message.lower():
                client.last_printer_status = True
            elif 'printer=no' in message.lower():
                client.last_printer_status = False

            if 'usb=yes' in message.lower():
                client.last_usb_status = True
            elif 'usb=no' in message.lower():
                client.last_usb_status = False

            current_app.logger.info(f"{mac} peripheral status updated from RDP log")

        # Parse video driver info
        elif 'video driver' in message.lower() or 'driver:' in message.lower():
            # Extract driver name (e.g., "Using video driver: intel")
            match = re.search(r'(?:driver|using)[:\s]+(\w+)', message.lower())
            if match:
                driver_name = match.group(1)
                if driver_name in ['autodetect', 'intel', 'vmware', 'universal', 'modesetting', 'vesa']:
                    client.video_driver_active = driver_name
                    current_app.logger.info(f"{mac} video driver: {driver_name}")

        db.session.add(log_entry)
        db.session.commit()
        
        return '', 200

    except Exception as e:
        current_app.logger.error(f"Client log failed: {e}", exc_info=True)
        return '', 500


# ============================================
# CLIENT LOG BATCH RECEPTION (FOR BUFFERED LOGS)
# ============================================
@api.route('/client-log/batch', methods=['POST'])
@client_log_rate_limit
def client_log_batch():
    """Receive batch of logs from thin clients (no auth)

    Rate limit: 60 requests per minute per MAC address
    Format: Each line is: timestamp|level|message|mac
    Example: 1699999999|INFO|Boot started|AA:BB:CC:DD:EE:FF
    """
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']
        db = model_classes['db']

        # Read batch data from request body
        batch_data = request.data.decode('utf-8', errors='ignore')

        if not batch_data:
            return '', 400

        # Parse each line
        lines = batch_data.strip().split('\n')
        logs_processed = 0
        logs_failed = 0

        for line in lines:
            if not line.strip():
                continue

            try:
                # Parse format: timestamp|level|message|mac
                parts = line.split('|', 3)
                if len(parts) != 4:
                    logs_failed += 1
                    continue

                timestamp_str, level, message, mac = parts
                mac = mac.upper().strip()
                level = level.upper().strip()

                # Validate
                if not mac or not message:
                    logs_failed += 1
                    continue

                # Security limits
                if len(mac) > MAX_MAC_LENGTH:
                    logs_failed += 1
                    continue

                if len(message) > MAX_LOG_MESSAGE_SIZE:
                    message = message[:MAX_LOG_MESSAGE_SIZE] + '... [TRUNCATED]'

                # Validate level
                if level not in ['DEBUG', 'INFO', 'WARN', 'ERROR', 'CRITICAL']:
                    level = 'INFO'

                # Find or create client
                client = Client.query.filter_by(mac=mac).first()
                client_ip = get_client_ip()

                if not client:
                    client = Client(
                        mac=mac,
                        hostname=f"TC-{mac[-8:].replace(':', '')}",
                        is_active=True,
                        last_ip=client_ip,
                        last_seen=models.get_kyiv_time()
                    )
                    db.session.add(client)
                    db.session.flush()

                # Classify log category
                category = classify_log(message)

                # Format message
                formatted_message = message.strip()

                # Create log entry
                log_entry = ClientLog(
                    client_id=client.id,
                    event_type=level,
                    category=category,
                    details=formatted_message,
                    ip_address=client_ip
                )
                db.session.add(log_entry)
                logs_processed += 1

            except Exception as line_error:
                logs_failed += 1
                continue

        # Commit all logs in one transaction
        if logs_processed > 0:
            db.session.commit()

        return f'{logs_processed}/{logs_processed + logs_failed}', 200

    except Exception as e:
        current_app.logger.error(f"Batch log processing failed: {e}", exc_info=True)
        db.session.rollback()
        return '', 500


# ============================================
# GET CLIENT LOGS
# ============================================
@api.route('/clients/<int:cid>/logs', methods=['GET'])
@login_required
def get_client_logs(cid):
    """Get logs for specific client"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']
        
        client = Client.query.get_or_404(cid)
        
        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        limit = request.args.get('limit', 500, type=int)
        
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
        
        query = ClientLog.query.filter(
            ClientLog.client_id == cid,
            ClientLog.timestamp >= cutoff_time
        )
        
        if level and level.upper() != 'ALL':
            query = query.filter(ClientLog.event_type == level.upper())
        
        logs = query.order_by(ClientLog.timestamp.desc()).limit(limit).all()

        # Filter by category using stored field from database
        if category and category != 'all':
            filtered_logs = []
            for log in logs:
                # Use stored category from database, fallback to classification if missing
                log_category = log.category if log.category else classify_log(log.details or '')
                if log_category == category:
                    filtered_logs.append(log)
            logs = filtered_logs

        # Return category from database
        result = []
        for log in logs:
            result.append({
                'id': log.id,
                'client_id': log.client_id,
                'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                'level': log.event_type or 'INFO',
                'message': log.details or '',
                'ip_address': log.ip_address,
                'category': log.category if log.category else 'other'
            })
        
        return jsonify(result)

    except Exception as e:
        current_app.logger.error(f"Get client logs failed: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500


# ============================================
# UNIFIED LOGS (SERVER + CLIENT)
# ============================================
@api.route('/clients/<int:cid>/logs/unified', methods=['GET'])
@login_required
def get_unified_logs(cid):
    """
    Get unified logs for specific client (SERVER + CLIENT logs merged)

    This endpoint combines:
    - Client logs from database (what client reported)
    - Server logs from files filtered by client's MAC and IP (what server saw)

    Returns chronological timeline with [SERVER] and [CLIENT] markers
    """
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']

        client = Client.query.get_or_404(cid)

        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        source_filter = request.args.get('source', 'all')  # all, server, client
        limit = request.args.get('limit', 500, type=int)

        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        unified_logs = []

        # ============================================
        # 1. GET CLIENT LOGS (from database)
        # ============================================
        if source_filter in ['all', 'client']:
            query = ClientLog.query.filter(
                ClientLog.client_id == cid,
                ClientLog.timestamp >= cutoff_time
            )

            if level and level.upper() != 'ALL':
                query = query.filter(ClientLog.event_type == level.upper())

            client_logs = query.order_by(ClientLog.timestamp.desc()).limit(limit).all()

            for log in client_logs:
                # Use stored category from database
                log_category = log.category if log.category else classify_log(log.details or '')

                # Apply category filter
                if category and category != 'all' and log_category != category:
                    continue

                unified_logs.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'timestamp_obj': log.timestamp,  # For sorting
                    'source': 'CLIENT',
                    'level': log.event_type or 'INFO',
                    'category': log_category,
                    'message': log.details or '',
                    'ip_address': log.ip_address
                })

        # ============================================
        # 2. GET SERVER LOGS (from files)
        # ============================================
        if source_filter in ['all', 'server']:
            server_logs = _parse_server_logs_for_client(
                client.mac,
                client.last_ip,
                hours,
                level,
                category
            )
            unified_logs.extend(server_logs)

        # ============================================
        # 3. SORT BY TIMESTAMP (newest first)
        # ============================================
        unified_logs.sort(key=lambda x: x.get('timestamp_obj') or x.get('timestamp') or '', reverse=True)

        # Remove timestamp_obj (was only for sorting)
        for log in unified_logs:
            log.pop('timestamp_obj', None)

        # Apply limit
        unified_logs = unified_logs[:limit]

        return jsonify({
            'client_mac': client.mac,
            'client_ip': client.last_ip,
            'logs': unified_logs,
            'count': len(unified_logs)
        })

    except Exception as e:
        current_app.logger.error(f"Get unified logs failed: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500


def _parse_server_logs_for_client(mac, ip, hours, level_filter=None, category_filter=None):
    """
    Parse server logs (TFTP, NGINX, APP) for specific client

    Args:
        mac: Client MAC address (e.g., D8:9E:F3:87:D3:6F)
        ip: Client IP address (e.g., 172.18.39.100)
        hours: How many hours back to search
        level_filter: Filter by log level (INFO, WARN, ERROR)
        category_filter: Filter by category

    Returns:
        List of log entries in unified format
    """
    from datetime import datetime
    import pytz

    server_logs = []
    kyiv_tz = pytz.timezone('Europe/Kiev')
    cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

    # Normalize MAC address (remove colons, lowercase)
    mac_normalized = mac.replace(':', '').lower() if mac else ''
    mac_with_colons = mac.upper() if mac else ''

    # ============================================
    # PARSE TFTP LOGS (syslog)
    # ============================================
    try:
        result = subprocess.run(
            ['grep', '-i', 'tftpd', '/var/log/syslog'],
            capture_output=True,
            text=True,
            timeout=5
        )

        for line in result.stdout.split('\n'):
            if not line.strip():
                continue

            # Check if line contains client MAC or IP
            if mac and (mac_normalized in line.lower() or mac_with_colons in line):
                # Parse syslog timestamp (Jan 15 14:23:45)
                match = re.match(r'(\w+ \d+ \d+:\d+:\d+) .+ in\.tftpd\[\d+\]: (.+)', line)
                if match:
                    timestamp_str, message = match.groups()

                    # Parse timestamp (add current year)
                    now = datetime.now()
                    try:
                        log_time = datetime.strptime(f"{now.year} {timestamp_str}", "%Y %b %d %H:%M:%S")
                        log_time = kyiv_tz.localize(log_time)
                    except:
                        log_time = cutoff_time  # Fallback

                    # Check if within time range
                    if log_time < cutoff_time:
                        continue

                    # Determine level
                    level = 'INFO'
                    if 'error' in message.lower() or 'failed' in message.lower():
                        level = 'ERROR'
                    elif 'warn' in message.lower():
                        level = 'WARN'

                    # Apply level filter
                    if level_filter and level_filter.upper() != 'ALL' and level != level_filter.upper():
                        continue

                    # Determine category
                    log_category = 'boot'  # TFTP logs are usually boot-related

                    # Apply category filter
                    if category_filter and category_filter != 'all' and log_category != category_filter:
                        continue

                    server_logs.append({
                        'timestamp': log_time.isoformat(),
                        'timestamp_obj': log_time,
                        'source': 'SERVER',
                        'source_type': 'TFTP',
                        'level': level,
                        'category': log_category,
                        'message': f"[TFTP] {message}",
                        'ip_address': None
                    })

    except Exception as e:
        current_app.logger.warning(f"Failed to parse TFTP logs: {e}")

    # ============================================
    # PARSE NGINX ACCESS LOGS
    # ============================================
    if ip:
        try:
            result = subprocess.run(
                ['grep', ip, '/var/log/nginx/access.log'],
                capture_output=True,
                text=True,
                timeout=5
            )

            for line in result.stdout.split('\n'):
                if not line.strip():
                    continue

                # Parse nginx log format
                # 172.18.39.100 - - [15/Jan/2025:14:23:45 +0200] "GET /kernels/vmlinuz HTTP/1.1" 200 ...
                match = re.match(r'(\S+) - - \[([^\]]+)\] "([^"]+)" (\d+)', line)
                if match:
                    client_ip, timestamp_str, request, status_code = match.groups()

                    # Parse timestamp
                    try:
                        log_time = datetime.strptime(timestamp_str, "%d/%b/%Y:%H:%M:%S %z")
                        log_time = log_time.astimezone(kyiv_tz)
                    except:
                        continue

                    # Check if within time range
                    if log_time < cutoff_time:
                        continue

                    # Only include boot-related requests
                    if not any(path in request for path in ['/kernels/', '/initrds/', '/boot/', '/api/boot/']):
                        continue

                    # Determine level based on status code
                    status = int(status_code)
                    if status >= 500:
                        level = 'ERROR'
                    elif status >= 400:
                        level = 'WARN'
                    else:
                        level = 'INFO'

                    # Apply level filter
                    if level_filter and level_filter.upper() != 'ALL' and level != level_filter.upper():
                        continue

                    # Category
                    log_category = 'boot'

                    # Apply category filter
                    if category_filter and category_filter != 'all' and log_category != category_filter:
                        continue

                    server_logs.append({
                        'timestamp': log_time.isoformat(),
                        'timestamp_obj': log_time,
                        'source': 'SERVER',
                        'source_type': 'HTTP',
                        'level': level,
                        'category': log_category,
                        'message': f"[HTTP {status_code}] {request}",
                        'ip_address': client_ip
                    })

        except Exception as e:
            current_app.logger.warning(f"Failed to parse NGINX logs: {e}")

    # ============================================
    # PARSE APP LOGS
    # ============================================
    if ip or mac:
        try:
            # Search for both MAC and IP in app logs
            search_pattern = mac_with_colons if mac else ip

            result = subprocess.run(
                ['grep', search_pattern, '/var/log/thinclient/app.log'],
                capture_output=True,
                text=True,
                timeout=5
            )

            for line in result.stdout.split('\n'):
                if not line.strip():
                    continue

                # Parse app log format
                # [2025-01-15 14:23:45,123] INFO in api: Client D8:9E:F3:87:D3:6F requested boot config
                match = re.match(r'\[([^\]]+)\] (\w+) in \w+: (.+)', line)
                if match:
                    timestamp_str, level, message = match.groups()

                    # Parse timestamp
                    try:
                        log_time = datetime.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S,%f")
                        log_time = kyiv_tz.localize(log_time)
                    except:
                        try:
                            log_time = datetime.strptime(timestamp_str.split(',')[0], "%Y-%m-%d %H:%M:%S")
                            log_time = kyiv_tz.localize(log_time)
                        except:
                            continue

                    # Check if within time range
                    if log_time < cutoff_time:
                        continue

                    # Apply level filter
                    if level_filter and level_filter.upper() != 'ALL' and level != level_filter.upper():
                        continue

                    # Classify category
                    log_category = classify_log(message)

                    # Apply category filter
                    if category_filter and category_filter != 'all' and log_category != category_filter:
                        continue

                    server_logs.append({
                        'timestamp': log_time.isoformat(),
                        'timestamp_obj': log_time,
                        'source': 'SERVER',
                        'source_type': 'APP',
                        'level': level,
                        'category': log_category,
                        'message': f"[APP] {message}",
                        'ip_address': None
                    })

        except Exception as e:
            current_app.logger.warning(f"Failed to parse APP logs: {e}")

    return server_logs


# ============================================
# CLEAR CLIENT LOGS
# ============================================
@api.route('/clients/<int:cid>/logs/clear', methods=['POST'])
@login_required
def clear_client_logs(cid):
    """Clear logs for specific client"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']
        db = model_classes['db']
        
        client = Client.query.get_or_404(cid)
        
        data = request.json or {}
        period = data.get('period', 'all')
        
        if period == 'all':
            count = ClientLog.query.filter_by(client_id=cid).delete()
        elif period == 'older_than':
            hours = data.get('hours', 24)
            cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
            count = ClientLog.query.filter(
                ClientLog.client_id == cid,
                ClientLog.timestamp < cutoff_time
            ).delete()
        else:
            return jsonify({'error': 'Invalid period'}), 400
        
        db.session.commit()

        log_audit('LOGS_CLEARED', f'Cleared {count} logs for client {client.mac}')
        return jsonify({'success': True, 'deleted': count, 'deleted_count': count})

    except Exception as e:
        current_app.logger.error(f"Clear logs failed: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500


# ============================================
# GET ALL LOGS
# ============================================
@api.route('/logs/all', methods=['GET'])
@login_required
def get_all_logs():
    """Get all client logs with filtering"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        
        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        search = request.args.get('search', None)
        limit = request.args.get('limit', 200, type=int)
        
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
        
        query = ClientLog.query.filter(ClientLog.timestamp >= cutoff_time)
        
        if level and level.upper() != 'ALL':
            query = query.filter(ClientLog.event_type == level.upper())
        
        if search:
            query = query.filter(ClientLog.details.like(f'%{search}%'))
        
        logs = query.order_by(ClientLog.timestamp.desc()).limit(limit).all()
        
        # Filter by category using stored field from database
        if category and category != 'all':
            filtered_logs = []
            for log in logs:
                # Use stored category from database, fallback to classification if missing
                log_category = log.category if log.category else classify_log(log.details or '')
                if log_category == category:
                    filtered_logs.append(log)
            logs = filtered_logs

        result = {
            'count': len(logs),
            'logs': [{
                'id': log.id,
                'client_id': log.client_id,
                'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                'level': log.event_type or 'INFO',
                'message': log.details or '',
                'ip_address': log.ip_address,
                'category': log.category if log.category else 'other'
            } for log in logs]
        }
        
        return jsonify(result)

    except Exception as e:
        current_app.logger.error(f"Get all logs failed: {e}", exc_info=True)
        return jsonify({'count': 0, 'logs': []}), 200


# ============================================
# SEARCH LOGS
# ============================================
@api.route('/logs/search', methods=['GET'])
@login_required
def search_logs():
    """Search through client logs"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        
        search_query = request.args.get('query', '')
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        hours = request.args.get('hours', 24, type=int)
        limit = request.args.get('limit', 100, type=int)
        
        if not search_query:
            return jsonify({'error': 'Query parameter required'}), 400
        
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
        
        query = ClientLog.query.filter(
            ClientLog.timestamp >= cutoff_time,
            ClientLog.details.like(f'%{search_query}%')
        )
        
        if level and level.upper() != 'ALL':
            query = query.filter(ClientLog.event_type == level.upper())
        
        logs = query.order_by(ClientLog.timestamp.desc()).limit(limit).all()
        
        # Filter by category using stored field from database
        if category and category != 'all':
            filtered_logs = []
            for log in logs:
                # Use stored category from database, fallback to classification if missing
                log_category = log.category if log.category else classify_log(log.details or '')
                if log_category == category:
                    filtered_logs.append(log)
            logs = filtered_logs

        return jsonify({
            'query': search_query,
            'count': len(logs),
            'logs': [{
                'id': log.id,
                'client_id': log.client_id,
                'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                'level': log.event_type or 'INFO',
                'message': log.details or '',
                'ip_address': log.ip_address,
                'category': log.category if log.category else 'other'
            } for log in logs]
        })

    except Exception as e:
        current_app.logger.error(f"Search logs failed: {e}", exc_info=True)
        return jsonify({'query': search_query, 'count': 0, 'logs': []}), 200


# ============================================
# GET LOG CATEGORIES
# ============================================
@api.route('/logs/categories', methods=['GET'])
@login_required
def get_log_categories():
    """Get log categories with counts"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        
        hours = request.args.get('hours', 24, type=int)
        client_id = request.args.get('client_id', None, type=int)
        
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
        
        query = ClientLog.query.filter(ClientLog.timestamp >= cutoff_time)
        
        if client_id:
            query = query.filter(ClientLog.client_id == client_id)
        
        logs = query.all()

        # Підрахунок по категоріям (використовуємо збережену категорію)
        category_counts = {}
        for log in logs:
            # Use stored category, fallback to classification if missing
            category = log.category if hasattr(log, 'category') and log.category else classify_log(log.details or '')
            category_counts[category] = category_counts.get(category, 0) + 1
        
        # Формуємо результат
        category_names = {
            'all': 'All',
            'xserver': 'X Server',
            'freerdp': 'FreeRDP',
            'network': 'Network',
            'ntp': 'NTP',
            'boot': 'Boot',
            'print': 'Print',
            'system': 'System',
            'other': 'Other'
        }
        
        categories = []
        
        # Total
        categories.append({
            'id': 'all',
            'name': category_names['all'],
            'count': len(logs)
        })
        
        # Окремі категорії
        for cat_id in ['xserver', 'freerdp', 'network', 'ntp', 'boot', 'print', 'system', 'other']:
            count = category_counts.get(cat_id, 0)
            if count > 0:
                categories.append({
                    'id': cat_id,
                    'name': category_names[cat_id],
                    'count': count
                })
        
        return jsonify({
            'categories': categories,
            'total': len(logs)
        })

    except Exception as e:
        current_app.logger.error(f"Get categories failed: {e}", exc_info=True)
        return jsonify({'categories': [], 'total': 0}), 200


# ============================================
# LOG STATISTICS
# ============================================
@api.route('/logs/stats', methods=['GET'])
@login_required
def get_log_stats():
    """Get logging statistics"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        AuditLog = model_classes['AuditLog']
        
        now = models.get_kyiv_time()
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        
        total_client_logs = ClientLog.query.count()
        today_client_logs = ClientLog.query.filter(ClientLog.timestamp >= today_start).count()
        
        client_logs_by_level = {}
        for level in ['INFO', 'WARN', 'ERROR']:
            count = ClientLog.query.filter(
                ClientLog.timestamp >= today_start,
                ClientLog.event_type == level
            ).count()
            client_logs_by_level[level] = count
        
        # Category statistics using stored field from database
        logs_today = ClientLog.query.filter(ClientLog.timestamp >= today_start).all()
        category_counts = {}
        for log in logs_today:
            # Use stored category from database, fallback to classification if missing
            category = log.category if log.category else classify_log(log.details or '')
            category_counts[category] = category_counts.get(category, 0) + 1
        
        total_audit_logs = AuditLog.query.count()
        today_audit_logs = AuditLog.query.filter(AuditLog.timestamp >= today_start).count()
        
        return jsonify({
            'client_logs': {
                'total': total_client_logs,
                'today': today_client_logs,
                'by_level': client_logs_by_level,
                'by_category': category_counts
            },
            'audit_logs': {
                'total': total_audit_logs,
                'today': today_audit_logs
            }
        })

    except Exception as e:
        current_app.logger.error(f"Get stats failed: {e}", exc_info=True)
        return jsonify({'client_logs': {}, 'audit_logs': {}}), 200


# ============================================
# CLEAR OLD LOGS
# ============================================
@api.route('/logs/clear', methods=['POST'])
@login_required
def clear_old_logs():
    """Clear old logs"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        AuditLog = model_classes['AuditLog']
        db = model_classes['db']
        
        data = request.json or {}
        log_type = data.get('type', 'client')
        days = data.get('days', 7)
        
        cutoff_time = models.get_kyiv_time() - timedelta(days=days)
        
        if log_type == 'client':
            deleted = ClientLog.query.filter(ClientLog.timestamp < cutoff_time).delete()
        elif log_type == 'audit':
            deleted = AuditLog.query.filter(AuditLog.timestamp < cutoff_time).delete()
        else:
            return jsonify({'error': 'Invalid log type'}), 400
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'deleted': deleted,
            'type': f'{log_type}_logs'
        })

    except Exception as e:
        current_app.logger.error(f"Clear old logs failed: {e}", exc_info=True)
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


# ============================================
# AUDIT LOGS
# ============================================
@api.route('/audit-logs', methods=['GET'])
@login_required
def get_audit_logs():
    """Get audit logs"""
    try:
        model_classes = models.get_models()
        AuditLog = model_classes['AuditLog']
        
        hours = request.args.get('hours', 24, type=int)
        action = request.args.get('action', None)
        admin = request.args.get('admin', None)
        limit = request.args.get('limit', 100, type=int)
        
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)
        
        query = AuditLog.query.filter(AuditLog.timestamp >= cutoff_time)
        
        if action:
            query = query.filter(AuditLog.action == action.upper())
        if admin:
            query = query.filter(AuditLog.admin_username == admin)
        
        logs = query.order_by(AuditLog.timestamp.desc()).limit(limit).all()
        
        return jsonify([log.to_dict() for log in logs])

    except Exception as e:
        current_app.logger.error(f"Get audit logs failed: {e}", exc_info=True)
        return jsonify([]), 200


# ============================================
# EXPORT CLIENT LOGS
# ============================================
@api.route('/clients/<int:cid>/logs/export', methods=['GET'])
@login_required
def export_client_logs(cid):
    """Export client logs to CSV or JSON"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']

        client = Client.query.get_or_404(cid)

        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        format_type = request.args.get('format', 'csv').lower()

        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        query = ClientLog.query.filter(
            ClientLog.client_id == cid,
            ClientLog.timestamp >= cutoff_time
        )

        if level and level.upper() != 'ALL':
            query = query.filter(ClientLog.event_type == level.upper())

        if category and category != 'all':
            query = query.filter(ClientLog.category == category)

        logs = query.order_by(ClientLog.timestamp.desc()).all()

        if format_type == 'json':
            # Export as JSON
            result = []
            for log in logs:
                result.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'level': log.event_type or 'INFO',
                    'category': log.category if log.category else 'other',
                    'message': log.details or '',
                    'ip_address': log.ip_address
                })

            from flask import make_response
            response = make_response(jsonify(result))
            response.headers['Content-Disposition'] = f'attachment; filename=logs_{client.mac}_{models.get_kyiv_time().strftime("%Y%m%d_%H%M%S")}.json'
            response.headers['Content-Type'] = 'application/json'
            return response

        else:
            # Export as CSV
            import csv
            import io

            output = io.StringIO()
            writer = csv.writer(output)

            # Write header
            writer.writerow(['Timestamp', 'Level', 'Category', 'Message', 'IP Address'])

            # Write data
            for log in logs:
                writer.writerow([
                    log.timestamp.strftime('%Y-%m-%d %H:%M:%S') if log.timestamp else '',
                    log.event_type or 'INFO',
                    log.category if log.category else 'other',
                    log.details or '',
                    log.ip_address or ''
                ])

            from flask import make_response
            response = make_response(output.getvalue())
            response.headers['Content-Disposition'] = f'attachment; filename=logs_{client.mac}_{models.get_kyiv_time().strftime("%Y%m%d_%H%M%S")}.csv'
            response.headers['Content-Type'] = 'text/csv'
            return response

    except Exception as e:
        current_app.logger.error(f"Export logs failed: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500


# ============================================
# EXPORT ALL LOGS
# ============================================
@api.route('/logs/export', methods=['GET'])
@login_required
def export_all_logs():
    """Export all client logs to CSV or JSON"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        ClientLog = model_classes['ClientLog']

        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', None)
        category = request.args.get('category', None)
        mac = request.args.get('mac', None)
        search = request.args.get('search', None)
        format_type = request.args.get('format', 'csv').lower()

        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        # Build query with JOIN to get client info
        query = ClientLog.query.join(Client, ClientLog.client_id == Client.id, isouter=True).filter(
            ClientLog.timestamp >= cutoff_time
        )

        if level and level.upper() != 'ALL':
            query = query.filter(ClientLog.event_type == level.upper())

        if category and category != 'all' and category:
            query = query.filter(ClientLog.category == category)

        if mac:
            query = query.filter(Client.mac.like(f'%{mac}%'))

        if search:
            query = query.filter(ClientLog.details.like(f'%{search}%'))

        logs = query.order_by(ClientLog.timestamp.desc()).limit(5000).all()

        if format_type == 'json':
            # Export as JSON
            result = []
            for log in logs:
                client = log.client if hasattr(log, 'client') and log.client else None
                result.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'level': log.event_type or 'INFO',
                    'category': log.category if log.category else 'other',
                    'message': log.details or '',
                    'ip_address': log.ip_address,
                    'client_mac': client.mac if client else None,
                    'client_hostname': client.hostname if client else None
                })

            from flask import make_response
            response = make_response(jsonify(result))
            response.headers['Content-Disposition'] = f'attachment; filename=all_logs_{models.get_kyiv_time().strftime("%Y%m%d_%H%M%S")}.json'
            response.headers['Content-Type'] = 'application/json'
            return response

        else:
            # Export as CSV
            import csv
            import io

            output = io.StringIO()
            writer = csv.writer(output)

            # Write header
            writer.writerow(['Timestamp', 'Client MAC', 'Client Hostname', 'Level', 'Category', 'Message', 'IP Address'])

            # Write data
            for log in logs:
                client = log.client if hasattr(log, 'client') and log.client else None
                writer.writerow([
                    log.timestamp.strftime('%Y-%m-%d %H:%M:%S') if log.timestamp else '',
                    client.mac if client else '',
                    client.hostname if client else '',
                    log.event_type or 'INFO',
                    log.category if log.category else 'other',
                    log.details or '',
                    log.ip_address or ''
                ])

            from flask import make_response
            response = make_response(output.getvalue())
            response.headers['Content-Disposition'] = f'attachment; filename=all_logs_{models.get_kyiv_time().strftime("%Y%m%d_%H%M%S")}.csv'
            response.headers['Content-Type'] = 'text/csv'
            return response

    except Exception as e:
        current_app.logger.error(f"Export all logs failed: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500


# ============================================
# ============================================
# NOTE: Server logs endpoints moved to api/system.py
# Use /api/server-logs and /api/server-logs/download instead
# ============================================
# TFTP LOGS
# ============================================
@api.route('/logs/tftp', methods=['GET'])
@login_required
def get_tftp_logs(lines=100):
    """Get TFTP logs from syslog"""
    
    if isinstance(lines, str):
        lines = request.args.get('lines', 100, type=int)
    
    try:
        cmd = f"grep -i 'tftpd' /var/log/syslog | tail -n {lines}"
        
        result = subprocess.run(
            cmd,
            shell=True,
            capture_output=True,
            text=True,
            timeout=5
        )
        
        tftp_logs = []
        for line in result.stdout.split('\n'):
            if line.strip():
                # Parse syslog line
                match = re.match(r'(\w+ \d+ \d+:\d+:\d+) .+ in\.tftpd\[\d+\]: (.+)', line)
                if match:
                    timestamp, message = match.groups()
                    tftp_logs.append({
                        'timestamp': timestamp,
                        'message': message
                    })
        
        return jsonify({
            'logs': tftp_logs,
            'count': len(tftp_logs)
        })
        
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Timeout reading TFTP logs'}), 500
    except Exception as e:
        return jsonify({'error': str(e)}), 500