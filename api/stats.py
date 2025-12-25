#!/usr/bin/env python3
"""
Statistics API Routes for Dashboard
Provides peripheral usage stats, error logs, metrics, and initramfs info
"""

from flask import jsonify, request, current_app
from . import api
import models
from utils import login_required
from datetime import timedelta, datetime
import os


@api.route('/stats/peripherals', methods=['GET'])
@login_required
def peripheral_stats():
    """Get peripheral usage statistics across all clients"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']

        # Count clients with each peripheral enabled
        total_clients = Client.query.filter_by(is_active=True).count()

        sound_enabled = Client.query.filter_by(is_active=True, sound_enabled=True).count()
        printer_enabled = Client.query.filter_by(is_active=True, printer_enabled=True).count()
        usb_enabled = Client.query.filter_by(is_active=True, usb_redirect=True).count()
        clipboard_enabled = Client.query.filter_by(is_active=True, clipboard_enabled=True).count()
        drives_enabled = Client.query.filter_by(is_active=True, drives_redirect=True).count()
        multimon_enabled = Client.query.filter_by(is_active=True, multimon_enabled=True).count()

        return jsonify({
            'total': total_clients,
            'sound': sound_enabled,
            'printer': printer_enabled,
            'usb': usb_enabled,
            'clipboard': clipboard_enabled,
            'drives': drives_enabled,
            'multimon': multimon_enabled
        })

    except Exception as e:
        current_app.logger.error(f"Peripheral stats: {e}", exc_info=True)
        return jsonify({
            'total': 0,
            'sound': 0,
            'printer': 0,
            'usb': 0,
            'clipboard': 0,
            'drives': 0,
            'multimon': 0
        }), 200


@api.route('/logs/errors', methods=['GET'])
@login_required
def get_errors():
    """Get recent error logs"""
    try:
        model_classes = models.get_models()
        ClientLog = model_classes['ClientLog']
        Client = model_classes['Client']

        category = request.args.get('category', None)
        limit = request.args.get('limit', 10, type=int)
        hours = request.args.get('hours', 24, type=int)

        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        # Query ERROR level logs with JOIN to avoid N+1 problem
        query = ClientLog.query.join(Client, ClientLog.client_id == Client.id, isouter=True).filter(
            ClientLog.event_type == 'ERROR',
            ClientLog.timestamp >= cutoff_time
        )

        if category:
            query = query.filter(ClientLog.category == category)

        logs = query.order_by(ClientLog.timestamp.desc()).limit(limit).all()

        result_logs = []
        for log in logs:
            # Client info already loaded via JOIN
            client = log.client if hasattr(log, 'client') and log.client else None

            result_logs.append({
                'id': log.id,
                'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                'client_hostname': client.hostname if client else 'Unknown',
                'client_mac': client.mac if client else None,
                'message': log.details or '',
                'category': log.category or 'other'
            })

        return jsonify({
            'count': len(result_logs),
            'logs': result_logs
        })

    except Exception as e:
        current_app.logger.error(f"Get errors: {e}", exc_info=True)
        return jsonify({'count': 0, 'logs': []}), 200


@api.route('/clients/<int:cid>/metrics/history', methods=['GET'])
@login_required
def get_metrics_history(cid):
    """
    Get historical metrics for a client

    NOTE: This is a placeholder implementation.
    For production, you would need to:
    1. Create a ClientMetrics table to store historical data
    2. Have heartbeat endpoint save metrics to this table
    3. Query historical data here

    Current implementation returns mock data.
    """
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']

        client = Client.query.get_or_404(cid)

        # TODO: Implement actual historical data storage
        # For now, return current metrics as single point
        from datetime import datetime

        now = models.get_kyiv_time()

        return jsonify({
            'timestamps': [now.isoformat()],
            'cpu': [client.cpu_usage or 0],
            'ram': [client.mem_usage or 0]
        })

    except Exception as e:
        current_app.logger.error(f"Get metrics history: {e}", exc_info=True)
        return jsonify({
            'timestamps': [],
            'cpu': [],
            'ram': []
        }), 200


# ============================================
# INITRAMFS INFO
# ============================================
@api.route('/initramfs/info/<driver>', methods=['GET'])
def initramfs_info(driver):
    """Get info about initramfs for specific driver"""
    try:
        driver_map = {
            'autodetect': 'initrd-autodetect.img',
            'intel': 'initrd-intel.img',
            'vmware': 'initrd-vmware.img',
            'universal': 'initrd-universal.img',
            # Legacy mappings for backward compatibility
            'auto': 'initrd-autodetect.img',
            'modesetting': 'initrd-universal.img',
            'generic': 'initrd-universal.img'
        }

        filename = driver_map.get(driver, 'initrd-minimal.img')
        filepath = f"/var/www/thinclient/initrds/{filename}"

        info = {
            'driver': driver,
            'filename': filename,
            'exists': os.path.exists(filepath),
            'size_mb': 0
        }

        if info['exists']:
            info['size_mb'] = round(os.path.getsize(filepath) / 1024 / 1024, 1)

        return jsonify(info)

    except Exception as e:
        current_app.logger.error(f"Initramfs info: {e}", exc_info=True)
        return jsonify({
            'driver': driver,
            'filename': 'initrd-minimal.img',
            'exists': False,
            'size_mb': 0
        }), 200


# ============================================
# INITRAMFS LIST
# ============================================
@api.route('/initramfs/list', methods=['GET'])
@login_required
def initramfs_list():
    """List all initramfs images with statistics"""
    try:
        model_classes = models.get_models()
        Client = model_classes['Client']
        db = model_classes['db']

        initramfs_dir = '/var/www/thinclient/initrds'

        variants = [
            {'driver': 'minimal', 'filename': 'initrd-minimal.img'},
            {'driver': 'autodetect', 'filename': 'initrd-autodetect.img'},
            {'driver': 'intel', 'filename': 'initrd-intel.img'},
            {'driver': 'vmware', 'filename': 'initrd-vmware.img'},
            {'driver': 'universal', 'filename': 'initrd-universal.img'}
        ]

        images = []
        for variant in variants:
            filepath = os.path.join(initramfs_dir, variant['filename'])

            info = {
                'driver': variant['driver'],
                'filename': variant['filename'],
                'exists': os.path.exists(filepath),
                'size_mb': 0,
                'client_count': 0,
                'modified': None
            }

            if info['exists']:
                info['size_mb'] = round(os.path.getsize(filepath) / 1024 / 1024, 1)
                info['modified'] = datetime.fromtimestamp(os.path.getmtime(filepath)).isoformat()

            # Count clients using this driver
            if variant['driver'] == 'minimal':
                info['client_count'] = Client.query.filter(
                    db.or_(Client.video_driver == None, Client.video_driver == '')
                ).count()
            elif variant['driver'] == 'universal':
                # Universal catches modesetting, generic, universal
                info['client_count'] = Client.query.filter(
                    db.or_(
                        Client.video_driver == 'universal',
                        Client.video_driver == 'modesetting',
                        Client.video_driver == 'generic'
                    )
                ).count()
            elif variant['driver'] == 'autodetect':
                # Autodetect catches autodetect and auto
                info['client_count'] = Client.query.filter(
                    db.or_(
                        Client.video_driver == 'autodetect',
                        Client.video_driver == 'auto'
                    )
                ).count()
            else:
                info['client_count'] = Client.query.filter_by(
                    video_driver=variant['driver']
                ).count()

            images.append(info)

        return jsonify({'images': images})

    except Exception as e:
        current_app.logger.error(f"Initramfs list: {e}", exc_info=True)
        return jsonify({'images': []}), 200
