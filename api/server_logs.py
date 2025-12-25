#!/usr/bin/env python3
"""
Server Logs API Routes
Handles server-side logs from various sources
"""

from flask import request, jsonify, current_app
from datetime import timedelta
import subprocess
import os
from . import api
import models
from utils import login_required


# ============================================
# GET UNIFIED SERVER LOGS
# ============================================
@api.route('/server-logs/unified', methods=['GET'])
@login_required
def get_server_logs_unified():
    """Get unified server logs from multiple sources"""
    try:
        hours = request.args.get('hours', 24, type=int)
        level = request.args.get('level', 'all', type=str)
        category = request.args.get('category', 'all', type=str)

        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        all_logs = []

        # 1. ADMIN logs from audit_log table
        if category in ['all', 'admin']:
            model_classes = models.get_models()
            AuditLog = model_classes['AuditLog']

            admin_logs = AuditLog.query.filter(
                AuditLog.timestamp >= cutoff_time
            ).order_by(AuditLog.timestamp.desc()).limit(500).all()

            for log in admin_logs:
                all_logs.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'level': 'INFO',
                    'category': 'admin',
                    'message': f"{log.action}: {log.details or ''} (by {log.admin_username or 'system'})"
                })

        # 2. REGISTRATION logs from client_log table
        if category in ['all', 'registration']:
            model_classes = models.get_models()
            ClientLog = model_classes['ClientLog']

            reg_logs = ClientLog.query.filter(
                ClientLog.timestamp >= cutoff_time,
                ClientLog.category == 'registration'
            ).order_by(ClientLog.timestamp.desc()).limit(500).all()

            for log in reg_logs:
                all_logs.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'level': log.event_type or 'INFO',
                    'category': 'registration',
                    'message': log.details or ''
                })

        # 3. ADMIN actions from client_log (deletion, updates)
        if category in ['all', 'admin']:
            model_classes = models.get_models()
            ClientLog = model_classes['ClientLog']

            admin_action_logs = ClientLog.query.filter(
                ClientLog.timestamp >= cutoff_time,
                ClientLog.category == 'admin'
            ).order_by(ClientLog.timestamp.desc()).limit(500).all()

            for log in admin_action_logs:
                all_logs.append({
                    'timestamp': log.timestamp.isoformat() if log.timestamp else None,
                    'level': log.event_type or 'WARN',
                    'category': 'admin',
                    'message': log.details or ''
                })

        # 4. APPLICATION logs from app.log
        if category in ['all', 'application']:
            app_logs = read_log_file('/var/log/thinclient/app.log', hours)
            for line in app_logs:
                log_level = extract_log_level(line)
                if level != 'all' and log_level != level:
                    continue

                all_logs.append({
                    'timestamp': extract_timestamp(line),
                    'level': log_level,
                    'category': 'application',
                    'message': line
                })

        # 5. ERRORS from error.log
        if category in ['all', 'errors']:
            error_logs = read_log_file('/var/log/thinclient/error.log', hours)
            for line in error_logs:
                all_logs.append({
                    'timestamp': extract_timestamp(line),
                    'level': 'ERROR',
                    'category': 'errors',
                    'message': line
                })

        # 6. TFTP logs from syslog
        if category in ['all', 'tftp']:
            tftp_logs = read_syslog_filtered('tftp', hours)
            for line in tftp_logs:
                all_logs.append({
                    'timestamp': extract_timestamp(line),
                    'level': 'INFO',
                    'category': 'tftp',
                    'message': line
                })

        # 7. NGINX ACCESS logs
        if category in ['all', 'nginx-access']:
            nginx_access_logs = read_log_file('/var/log/nginx/access.log', hours, limit=200)
            for line in nginx_access_logs:
                all_logs.append({
                    'timestamp': extract_nginx_timestamp(line),
                    'level': 'INFO',
                    'category': 'nginx-access',
                    'message': line
                })

        # 8. NGINX ERROR logs
        if category in ['all', 'nginx-error']:
            nginx_error_logs = read_log_file('/var/log/nginx/error.log', hours, limit=200)
            for line in nginx_error_logs:
                all_logs.append({
                    'timestamp': extract_timestamp(line),
                    'level': 'ERROR',
                    'category': 'nginx-error',
                    'message': line
                })

        # 9. SYSTEM logs from syslog
        if category in ['all', 'system']:
            system_logs = read_syslog_filtered('systemd|kernel|cron', hours, limit=100)
            for line in system_logs:
                all_logs.append({
                    'timestamp': extract_timestamp(line),
                    'level': extract_log_level(line),
                    'category': 'system',
                    'message': line
                })

        # Sort by timestamp descending
        all_logs.sort(key=lambda x: x['timestamp'] or '', reverse=True)

        # Apply level filter
        if level != 'all':
            all_logs = [log for log in all_logs if log['level'] == level]

        # Limit results
        all_logs = all_logs[:500]

        return jsonify({
            'logs': all_logs,
            'count': len(all_logs)
        })

    except Exception as e:
        current_app.logger.error(f"Server logs unified: {e}", exc_info=True)
        import traceback
        traceback.print_exc()
        return jsonify({'error': str(e), 'logs': [], 'count': 0}), 500


# ============================================
# GET SERVER LOGS CATEGORIES
# ============================================
@api.route('/server-logs/categories', methods=['GET'])
@login_required
def get_server_logs_categories():
    """Get server log categories with counts"""
    try:
        hours = request.args.get('hours', 24, type=int)
        cutoff_time = models.get_kyiv_time() - timedelta(hours=hours)

        counts = {
            'application': 0,
            'errors': 0,
            'admin': 0,
            'registration': 0,
            'tftp': 0,
            'nginx-access': 0,
            'nginx-error': 0,
            'system': 0
        }

        # Count from database
        model_classes = models.get_models()

        # Admin logs from audit_log
        AuditLog = model_classes['AuditLog']
        counts['admin'] += AuditLog.query.filter(AuditLog.timestamp >= cutoff_time).count()

        # Registration logs from client_log
        ClientLog = model_classes['ClientLog']
        counts['registration'] = ClientLog.query.filter(
            ClientLog.timestamp >= cutoff_time,
            ClientLog.category == 'registration'
        ).count()

        # Admin actions from client_log
        counts['admin'] += ClientLog.query.filter(
            ClientLog.timestamp >= cutoff_time,
            ClientLog.category == 'admin'
        ).count()

        # Count from log files
        counts['application'] = count_log_lines('/var/log/thinclient/app.log', hours)
        counts['errors'] = count_log_lines('/var/log/thinclient/error.log', hours)
        counts['nginx-access'] = count_log_lines('/var/log/nginx/access.log', hours, limit=200)
        counts['nginx-error'] = count_log_lines('/var/log/nginx/error.log', hours, limit=200)
        counts['tftp'] = count_syslog_filtered('tftp', hours)
        counts['system'] = count_syslog_filtered('systemd|kernel', hours, limit=100)

        # Build categories response
        total = sum(counts.values())

        categories = [
            {'id': 'all', 'name': 'All', 'count': total}
        ]

        for cat_id, count in counts.items():
            if count > 0:
                categories.append({
                    'id': cat_id,
                    'name': cat_id.replace('-', ' ').title(),
                    'count': count
                })

        return jsonify({
            'categories': categories,
            'total': total
        })

    except Exception as e:
        current_app.logger.error(f"Server logs categories: {e}", exc_info=True)
        import traceback
        traceback.print_exc()
        return jsonify({'categories': [], 'total': 0}), 500


# ============================================
# HELPER FUNCTIONS
# ============================================

def read_log_file(path, hours, limit=500):
    """Read log file and return recent lines"""
    if not os.path.exists(path):
        return []

    try:
        result = subprocess.run(
            ['tail', '-n', str(limit), path],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            return [line for line in lines if line.strip()]
        return []

    except Exception as e:
        current_app.logger.error(f"Reading {path}: {e}", exc_info=True)
        return []


def read_syslog_filtered(pattern, hours, limit=200):
    """Read syslog with grep filter"""
    if not os.path.exists('/var/log/syslog'):
        return []

    try:
        result = subprocess.run(
            ['grep', '-E', pattern, '/var/log/syslog'],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            return lines[-limit:] if len(lines) > limit else lines
        return []

    except Exception as e:
        current_app.logger.error(f"Reading syslog with filter {pattern}: {e}", exc_info=True)
        return []


def count_log_lines(path, hours, limit=500):
    """Count lines in log file"""
    lines = read_log_file(path, hours, limit)
    return len(lines)


def count_syslog_filtered(pattern, hours, limit=200):
    """Count lines in syslog with filter"""
    lines = read_syslog_filtered(pattern, hours, limit)
    return len(lines)


def extract_timestamp(line):
    """Extract timestamp from log line"""
    import re
    from datetime import datetime

    # Try multiple timestamp formats
    patterns = [
        r'\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})',  # [2025-10-23 12:34:56]
        r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})',    # 2025-10-23T12:34:56
        r'(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})',    # Oct 23 12:34:56
    ]

    for pattern in patterns:
        match = re.search(pattern, line)
        if match:
            try:
                ts_str = match.group(1)
                # Parse and convert to ISO format
                if 'T' in ts_str:
                    return ts_str
                elif '-' in ts_str:
                    dt = datetime.strptime(ts_str, '%Y-%m-%d %H:%M:%S')
                    return dt.isoformat()
                else:
                    # Syslog format (add current year)
                    year = datetime.now().year
                    dt = datetime.strptime(f"{year} {ts_str}", '%Y %b %d %H:%M:%S')
                    return dt.isoformat()
            except:
                pass

    return None


def extract_nginx_timestamp(line):
    """Extract timestamp from nginx log line"""
    import re
    from datetime import datetime

    # Nginx format: 172.18.39.198 - - [23/Oct/2025:12:34:56 +0200]
    match = re.search(r'\[(\d{2}/\w{3}/\d{4}:\d{2}:\d{2}:\d{2})', line)
    if match:
        try:
            ts_str = match.group(1)
            dt = datetime.strptime(ts_str, '%d/%b/%Y:%H:%M:%S')
            return dt.isoformat()
        except:
            pass

    return extract_timestamp(line)


def extract_log_level(line):
    """Extract log level from line"""
    import re

    line_upper = line.upper()

    if re.search(r'\b(ERROR|CRITICAL|FATAL|FAIL)\b', line_upper):
        return 'ERROR'
    elif re.search(r'\b(WARN|WARNING)\b', line_upper):
        return 'WARN'
    else:
        return 'INFO'
