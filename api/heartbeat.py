#!/usr/bin/env python3
"""
Thin-Server Heartbeat API
Client health monitoring and status tracking
"""

from flask import request, jsonify, current_app
from datetime import timedelta
from . import api
import models
import os
import json
from utils import get_client_ip


# ============================================
# HEARTBEAT ENDPOINT
# ============================================
@api.route('/heartbeat/<mac>', methods=['POST', 'GET'])
def heartbeat(mac):
    """
    Клієнт періодично викликає цей endpoint щоб повідомити що він живий
    Оновлює last_seen та встановлює status=online
    """
    try:
        # Normalize MAC
        from utils import validate_mac
        clean_mac = validate_mac(mac)
        if not clean_mac:
            return jsonify({'error': 'Invalid MAC address'}), 400

        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        client = Client.query.filter_by(mac=clean_mac, is_active=True).first()
        if not client:
            return jsonify({'error': 'Client not found'}), 404

        # Update last_seen and set status to online
        client.last_seen = models.get_kyiv_time()
        client.status = 'online'
        client.last_ip = get_client_ip()

        db.session.commit()

        return jsonify({
            'success': True,
            'status': 'online',
            'last_seen': client.last_seen.isoformat()
        })

    except Exception as e:
        current_app.logger.error(f"Heartbeat for {mac}: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error'}), 500


# ============================================
# UPDATE CLIENT STATUSES (CHECK TIMEOUTS)
# ============================================
def update_client_statuses():
    """
    Перевіряє last_seen всіх клієнтів і оновлює статуси
    - Якщо last_seen > 5 хвилин → offline
    - Якщо status=booting і last_seen > 10 хвилин → offline (не завантажився)
    """
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        now = models.get_kyiv_time()
        timeout_online = now - timedelta(minutes=5)   # 5 хвилин для online
        timeout_booting = now - timedelta(minutes=10)  # 10 хвилин для booting

        # Find clients that should be offline
        clients = Client.query.filter_by(is_active=True).all()

        updated_count = 0
        for client in clients:
            old_status = client.status

            # Якщо немає last_seen - встановити offline
            if not client.last_seen:
                if client.status != 'offline':
                    client.status = 'offline'
                    updated_count += 1
                continue

            # Якщо booting і минуло > 10 хвилин → offline
            if client.status == 'booting' and client.last_seen < timeout_booting:
                client.status = 'offline'
                updated_count += 1

            # Якщо online і минуло > 5 хвилин → offline
            elif client.status == 'online' and client.last_seen < timeout_online:
                client.status = 'offline'
                updated_count += 1

        if updated_count > 0:
            db.session.commit()
            current_app.logger.info(f"Updated {updated_count} client statuses to offline")

        return updated_count

    except Exception as e:
        current_app.logger.error(f"Update client statuses: {e}", exc_info=True)
        import traceback
        traceback.print_exc()
        return 0


# ============================================
# METRICS ENDPOINT
# ============================================
@api.route('/metrics', methods=['POST'])
def receive_metrics():
    """
    Receive performance metrics from thin clients
    Stores metrics in JSONL format for time-series analysis
    """
    try:
        data = request.json
        if not data or 'mac' not in data:
            return jsonify({'error': 'Invalid data'}), 400

        # Validate MAC
        from utils import validate_mac
        mac = validate_mac(data.get('mac'))
        if not mac:
            return jsonify({'error': 'Invalid MAC address'}), 400

        # Store metrics in file (JSONL format)
        metrics_dir = '/var/log/thinclient/metrics'
        os.makedirs(metrics_dir, mode=0o755, exist_ok=True)

        metrics_file = os.path.join(metrics_dir, f'{mac}.jsonl')

        # Add timestamp
        data['timestamp'] = models.get_kyiv_time().isoformat()
        data['server_received'] = models.get_kyiv_time().isoformat()

        # Write to file (append)
        with open(metrics_file, 'a') as f:
            f.write(json.dumps(data) + '\n')

        # Update client record with latest metrics
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        client = Client.query.filter_by(mac=mac).first()
        if client:
            client.last_seen = models.get_kyiv_time()
            client.last_ip = get_client_ip()

            # Update client metrics in database
            if 'cpu_usage' in data:
                client.cpu_usage = float(data['cpu_usage'])
            if 'mem_percent' in data:
                client.mem_usage = float(data['mem_percent'])
            if 'rx_bytes' in data:
                client.rx_bytes = int(data['rx_bytes'])
            if 'tx_bytes' in data:
                client.tx_bytes = int(data['tx_bytes'])

            # Update RDP connection status based on metrics
            if 'rdp_status' in data and data['rdp_status'] == 'connected':
                # Keep status as online when RDP is connected
                if client.status == 'booting':
                    client.status = 'online'

            db.session.commit()

        return jsonify({'status': 'ok', 'message': 'Metrics received'}), 200

    except Exception as e:
        current_app.logger.error(f"Metrics receive: {e}", exc_info=True)
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'Internal server error'}), 500


# ============================================
# DIAGNOSTIC ENDPOINT
# ============================================
@api.route('/diagnostic/<mac>', methods=['POST'])
def receive_diagnostic(mac):
    """
    Receive diagnostic report from thin client
    Stores full diagnostic text for debugging
    """
    try:
        # Validate MAC
        from utils import validate_mac
        clean_mac = validate_mac(mac)
        if not clean_mac:
            return jsonify({'error': 'Invalid MAC address'}), 400

        # Get diagnostic data (text format)
        diagnostic_data = request.get_data(as_text=True)
        if not diagnostic_data:
            return jsonify({'error': 'No data received'}), 400

        # Save diagnostic data
        diagnostic_dir = '/var/log/thinclient/diagnostics'
        os.makedirs(diagnostic_dir, mode=0o755, exist_ok=True)

        timestamp = models.get_kyiv_time().strftime('%Y%m%d_%H%M%S')
        filename = os.path.join(diagnostic_dir, f'{clean_mac}_{timestamp}.txt')

        with open(filename, 'w') as f:
            f.write(f"Thin-Server Diagnostic Report\n")
            f.write(f"MAC: {clean_mac}\n")
            f.write(f"Timestamp: {models.get_kyiv_time().isoformat()}\n")
            f.write(f"Remote IP: {get_client_ip()}\n")
            f.write(f"{'='*60}\n\n")
            f.write(diagnostic_data)

        # Update client record
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        client = Client.query.filter_by(mac=clean_mac).first()
        if client:
            client.last_seen = models.get_kyiv_time()
            db.session.commit()

        return jsonify({
            'status': 'received',
            'file': filename,
            'message': 'Diagnostic report saved'
        }), 200

    except Exception as e:
        current_app.logger.error(f"Diagnostic receive for {mac}: {e}", exc_info=True)
        import traceback
        traceback.print_exc()
        return jsonify({'error': 'Internal server error'}), 500
