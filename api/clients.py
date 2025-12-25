#!/usr/bin/env python3
"""
Thin-Server Client Management API
CRUD operations for thin clients
"""

from flask import request, jsonify
from . import api
import models
from models import db
from utils import login_required, validate_mac, log_audit, validate_client_params


@api.route('/clients', methods=['GET', 'POST'])
@login_required
def clients():
    """List or create clients"""
    
    # Get models
    model_classes = models.get_models()
    Client = model_classes['Client']
    db = model_classes['db']
    
    if request.method == 'POST':
        data = request.json

        # Comprehensive validation
        valid, error_msg = validate_client_params(data)
        if not valid:
            return jsonify({'error': error_msg}), 400

        # MAC is already normalized by validate_client_params
        mac = data['mac']

        if Client.query.filter_by(mac=mac).first():
            return jsonify({'error': 'MAC address already exists'}), 400
        
        # Create new client
        client = Client(
            mac=mac,
            hostname=data.get('hostname', f'tc-{mac.replace(":", "")[-6:]}'),
            location=data.get('location', ''),
            rdp_server=data.get('rdp_server') or data.get('server_config'),
            rdp_domain=data.get('rdp_domain', ''),
            rdp_username=data.get('rdp_username') or data.get('rdp_user', ''),
            rdp_password=data.get('rdp_password') or data.get('rdp_pass', ''),
            rdp_width=data.get('rdp_width'),
            rdp_height=data.get('rdp_height'),
            sound_enabled=data.get('sound_enabled', True),
            printer_enabled=data.get('printer_enabled', False),
            usb_redirect=data.get('usb_redirect', False),
            print_server_enabled=data.get('print_server_enabled', False),
            video_driver=data.get('video_driver', 'autodetect')
        )
        
        db.session.add(client)
        db.session.flush()  # Get client.id before creating log

        # Create log entry for manual client registration by admin
        ClientLog = model_classes['ClientLog']
        registration_log = ClientLog(
            client_id=client.id,
            event_type='INFO',
            category='registration',
            details=f'Manually registered by administrator. Hostname: {client.hostname}, Location: {client.location or "N/A"}, RDS: {client.rdp_server or "N/A"}',
            ip_address=request.remote_addr
        )
        db.session.add(registration_log)

        db.session.commit()

        log_audit('CLIENT_ADDED', f'MAC: {mac}, Location: {client.location}')
        return jsonify({
            'success': True,
            'id': client.id,
            'client': client.to_dict()
        }), 201
    
    # GET - list all active clients
    include_inactive = request.args.get('include_inactive', 'false').lower() == 'true'
    
    query = Client.query
    if not include_inactive:
        query = query.filter_by(is_active=True)
    
    clients = query.order_by(Client.hostname).all()
    return jsonify([c.to_dict() for c in clients])


@api.route('/clients/<int:cid>', methods=['GET', 'PUT', 'DELETE'])
@login_required
def client_detail(cid):
    """Get, update, or delete a client"""
    
    # Get models
    model_classes = models.get_models()
    Client = model_classes['Client']
    db = model_classes['db']
    
    client = Client.query.get_or_404(cid)
    
    if request.method == 'GET':
        return jsonify(client.to_dict())
    
    elif request.method == 'PUT':
        data = request.json
        
        # Update client fields
        if 'hostname' in data:
            client.hostname = data['hostname']
        if 'location' in data:
            client.location = data['location']
        
        # Support both old and new field names
        if 'rdp_server' in data or 'server_config' in data:
            client.rdp_server = data.get('rdp_server') or data.get('server_config')
        
        if 'rdp_domain' in data:
            client.rdp_domain = data['rdp_domain']
        
        if 'rdp_username' in data or 'rdp_user' in data:
            client.rdp_username = data.get('rdp_username') or data.get('rdp_user')
        
        if 'rdp_password' in data or 'rdp_pass' in data:
            client.rdp_password = data.get('rdp_password') or data.get('rdp_pass')

        # Note: resolution removed - auto-detected via xrandr on thin client
        if 'rdp_width' in data:
            client.rdp_width = data['rdp_width']
        if 'rdp_height' in data:
            client.rdp_height = data['rdp_height']
        
        if 'sound_enabled' in data:
            client.sound_enabled = data['sound_enabled']
        if 'printer_enabled' in data:
            client.printer_enabled = data['printer_enabled']
        if 'usb_redirect' in data:
            client.usb_redirect = data['usb_redirect']
        if 'print_server_enabled' in data:
            client.print_server_enabled = data['print_server_enabled']
        if 'video_driver' in data:
            client.video_driver = data['video_driver']
        
        if 'is_active' in data:
            client.is_active = data['is_active']

        # Create log entry for configuration update
        ClientLog = model_classes['ClientLog']
        changed_fields = []
        if 'hostname' in data:
            changed_fields.append(f"hostname={data['hostname']}")
        if 'rdp_server' in data or 'server_config' in data:
            changed_fields.append(f"rdp_server={client.rdp_server}")
        if 'rdp_username' in data or 'rdp_user' in data:
            changed_fields.append(f"rdp_username={client.rdp_username}")
        if 'is_active' in data:
            changed_fields.append(f"is_active={client.is_active}")

        if changed_fields:
            update_log = ClientLog(
                client_id=client.id,
                event_type='INFO',
                category='config',
                details=f'Configuration updated by administrator: {", ".join(changed_fields)}',
                ip_address=request.remote_addr
            )
            db.session.add(update_log)

        db.session.commit()

        log_audit('CLIENT_UPDATED', f'MAC: {client.mac}')
        return jsonify({
            'success': True,
            'client': client.to_dict()
        })
    
    elif request.method == 'DELETE':
        # Create log entry for deletion (before soft delete)
        ClientLog = model_classes['ClientLog']
        deletion_log = ClientLog(
            client_id=client.id,
            event_type='WARN',
            category='admin',
            details=f'Client deleted by administrator. Hostname: {client.hostname}, MAC: {client.mac}',
            ip_address=request.remote_addr
        )
        db.session.add(deletion_log)

        # Soft delete
        client.is_active = False
        db.session.commit()

        log_audit('CLIENT_DELETED', f'MAC: {client.mac}')
        return jsonify({'success': True})


@api.route('/clients/<int:cid>/enable', methods=['POST'])
@login_required
def enable_client(cid):
    """Enable/disable client"""
    
    model_classes = models.get_models()
    Client = model_classes['Client']
    db = model_classes['db']
    
    client = Client.query.get_or_404(cid)
    
    data = request.json or {}
    client.is_active = data.get('enabled', True)

    db.session.commit()

    status = 'enabled' if client.is_active else 'disabled'
    log_audit('CLIENT_STATUS', f'Client {client.mac} {status}')

    return jsonify({
        'success': True,
        'is_active': client.is_active
    })


# ============================================
# TOGGLE PERIPHERAL FEATURE
# ============================================
@api.route('/clients/<int:cid>/toggle/<feature>', methods=['POST'])
@login_required
def toggle_feature(cid, feature):
    """Toggle a peripheral feature on/off"""

    model_classes = models.get_models()
    Client = model_classes['Client']
    db = model_classes['db']

    client = Client.query.get_or_404(cid)

    # Map feature names to model fields
    feature_map = {
        'sound': 'sound_enabled',
        'printer': 'printer_enabled',
        'usb': 'usb_redirect',
        'clipboard': 'clipboard_enabled',
        'drives': 'drives_redirect',
        'compression': 'compression_enabled',
        'multimon': 'multimon_enabled',
        'printserver': 'print_server_enabled',
        'ssh': 'ssh_enabled'
    }

    if feature not in feature_map:
        return jsonify({'error': 'Invalid feature'}), 400

    field_name = feature_map[feature]

    # Toggle the field
    current_value = getattr(client, field_name, False)
    new_value = not current_value
    setattr(client, field_name, new_value)

    db.session.commit()

    log_audit('FEATURE_TOGGLED', f'Client {client.mac}: {feature} = {new_value}')

    return jsonify({
        'success': True,
        'feature': feature,
        'enabled': new_value
    })


# ============================================
# BULK UPDATE CLIENTS
# ============================================
@api.route('/clients/bulk-update', methods=['POST'])
@login_required
def bulk_update():
    """Update multiple clients at once"""

    model_classes = models.get_models()
    Client = model_classes['Client']
    db = model_classes['db']

    data = request.json or {}
    client_ids = data.get('client_ids', [])
    settings = data.get('settings', {})

    if not client_ids:
        return jsonify({'error': 'No clients selected'}), 400

    if not settings:
        return jsonify({'error': 'No settings provided'}), 400

    updated_count = 0

    for cid in client_ids:
        client = Client.query.get(cid)
        if not client:
            continue

        # Update peripheral settings
        if 'sound_enabled' in settings:
            client.sound_enabled = settings['sound_enabled']
        if 'multimon_enabled' in settings:
            client.multimon_enabled = settings['multimon_enabled']
        if 'printer_enabled' in settings:
            client.printer_enabled = settings['printer_enabled']
        if 'usb_redirect' in settings:
            client.usb_redirect = settings['usb_redirect']
        if 'clipboard_enabled' in settings:
            client.clipboard_enabled = settings['clipboard_enabled']
        if 'drives_redirect' in settings:
            client.drives_redirect = settings['drives_redirect']
        if 'compression_enabled' in settings:
            client.compression_enabled = settings['compression_enabled']
        if 'print_server_enabled' in settings:
            client.print_server_enabled = settings['print_server_enabled']

        # Note: resolution removed - auto-detected via xrandr on thin client

        updated_count += 1

    db.session.commit()

    log_audit('BULK_UPDATE', f'Updated {updated_count} clients with new settings')

    return jsonify({
        'success': True,
        'updated': updated_count
    })


# ============================================
# GET CLIENT METRICS
# ============================================
@api.route('/clients/<int:cid>/metrics', methods=['GET'])
@login_required
def get_client_metrics(cid):
    """Get current metrics for a client"""

    model_classes = models.get_models()
    Client = model_classes['Client']

    client = Client.query.get_or_404(cid)

    return jsonify({
        'cpu': client.cpu_usage or 0.0,
        'ram': client.mem_usage or 0.0,
        'rx_bytes': client.rx_bytes or 0,
        'tx_bytes': client.tx_bytes or 0,
        'uptime': client.uptime_seconds or 0
    })


@api.route('/clients/stats', methods=['GET'])
@login_required
def clients_stats():
    """Get client statistics"""

    # Update client statuses based on timeout
    from api.heartbeat import update_client_statuses
    update_client_statuses()

    model_classes = models.get_models()
    Client = model_classes['Client']

    from datetime import timedelta
    now = models.get_kyiv_time()
    today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week_start = today_start - timedelta(days=7)

    stats = {
        'total': Client.query.filter_by(is_active=True).count(),
        'online': Client.query.filter_by(is_active=True, status='online').count(),
        'booting': Client.query.filter_by(is_active=True, status='booting').count(),
        'offline': Client.query.filter_by(is_active=True, status='offline').count(),
        'online_today': Client.query.filter_by(is_active=True)\
                                     .filter(Client.last_boot >= today_start).count(),
        'online_week': Client.query.filter_by(is_active=True)\
                                    .filter(Client.last_boot >= week_start).count(),
        'total_boots': db.session.query(db.func.sum(Client.boot_count)).scalar() or 0
    }

    return jsonify(stats)