#!/usr/bin/env python3
"""
System Information API Routes
"""

from flask import jsonify, current_app
from . import api
from utils import login_required, get_system_stats
from config import Config
import subprocess


@api.route('/system/stats', methods=['GET'])
@login_required
def system_stats():
    """Get system statistics"""
    stats = get_system_stats()
    
    # Add system info
    stats['system'] = {
        'version': Config.VERSION,
        'server_ip': Config.SERVER_IP,
        'rds_server': Config.RDS_SERVER,
        'ntp_server': Config.NTP_SERVER
    }
    
    return jsonify(stats)


@api.route('/system/services', methods=['GET'])
@login_required
def system_services():
    """Get service status"""
    services = ['nginx', 'tftpd-hpa', 'thinclient-manager']
    status = {}
    
    for service in services:
        try:
            result = subprocess.run(
                ['systemctl', 'is-active', service],
                capture_output=True,
                text=True,
                timeout=2
            )
            status[service] = {
                'active': result.returncode == 0,
                'status': result.stdout.strip()
            }
        except Exception as e:
            status[service] = {
                'active': False,
                'status': 'unknown',
                'error': str(e)
            }
    
    return jsonify(status)


@api.route('/system/health', methods=['GET'])
def system_health():
    """Health check endpoint (no auth)"""
    try:
        import models
        model_classes = models.get_models()
        Client = model_classes['Client']
        
        # Test database
        Client.query.count()
        db_ok = True
    except Exception:
        db_ok = False
    
    # Check services
    services_ok = True
    try:
        result = subprocess.run(
            ['systemctl', 'is-active', 'thinclient-manager'],
            capture_output=True,
            timeout=2
        )
        if result.returncode != 0:
            services_ok = False
    except Exception:
        services_ok = False
    
    health = {
        'status': 'healthy' if (db_ok and services_ok) else 'unhealthy',
        'database': db_ok,
        'services': services_ok,
        'version': Config.VERSION
    }
    
    status_code = 200 if (db_ok and services_ok) else 503
    
    return jsonify(health), status_code


@api.route('/system/version', methods=['GET'])
def system_version():
    """Get version (no auth)"""
    return jsonify({
        'version': Config.VERSION,
        'name': 'Thin-Server ThinClient Manager'
    })


@api.route('/server-logs', methods=['GET'])
@login_required
def server_logs():
    """
    Get server logs from various sources

    Query params:
        source: Log source (nginx-access, nginx-error, app, error, maintenance, tftp, system, install, build, boot-files)
        lines: Number of lines to return (default 100)
    """
    from flask import request
    import os

    source = request.args.get('source', 'nginx-access')
    lines = int(request.args.get('lines', 100))

    # Log source mapping
    LOG_SOURCES = {
        'nginx-access': '/var/log/nginx/access.log',
        'nginx-error': '/var/log/nginx/error.log',
        'app': '/var/log/thinclient/app.log',
        'error': '/var/log/thinclient/error.log',
        'maintenance': '/var/log/thinclient/maintenance.log',
        'tftp': '/var/log/syslog',  # TFTP logs go to syslog
        'system': '/var/log/syslog',
        'install': '/var/log/thinclient/installation.log',
        'build': '/var/log/thinclient/build.log',
        'boot-files': '/var/log/nginx/access.log'  # Filter for /kernels/ /initrds/ /boot/
    }

    log_file = LOG_SOURCES.get(source)

    if not log_file:
        return jsonify({'error': 'Invalid log source'}), 400

    # Special handling for installation/build logs (with timestamp in filename)
    if source in ['install', 'build']:
        import glob
        install_logs = glob.glob('/var/log/thinclient/thin-server-install-*.log')
        if install_logs:
            # Get the most recent installation log
            log_file = max(install_logs, key=os.path.getmtime)
        else:
            return jsonify({
                'lines': ['No installation/build logs found (thin-server-install-*.log)'],
                'size': 0,
                'source': source
            })

    if not os.path.exists(log_file):
        return jsonify({
            'lines': [f'Log file not found: {log_file}'],
            'size': 0,
            'source': source
        })

    try:
        # Get file size
        file_size = os.path.getsize(log_file)

        # Read last N lines using tail
        result = subprocess.run(
            ['tail', '-n', str(lines), log_file],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode != 0:
            return jsonify({'error': 'Failed to read log file'}), 500

        log_lines = result.stdout.splitlines()

        # Filter for TFTP if needed
        if source == 'tftp':
            log_lines = [line for line in log_lines if 'tftpd' in line.lower() or 'tftp' in line.lower()]

        # Filter for boot files (/kernels/, /initrds/, /boot/)
        elif source == 'boot-files':
            log_lines = [line for line in log_lines if any(path in line for path in ['/kernels/', '/initrds/', '/boot/', '/api/boot/'])]

        return jsonify({
            'lines': log_lines,
            'size': file_size,
            'source': source,
            'file': log_file
        })

    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Timeout reading log file'}), 500
    except Exception as e:
        return jsonify({'error': f'Error reading logs: {str(e)}'}), 500


@api.route('/server-logs/download', methods=['GET'])
@login_required
def download_server_logs():
    """Download server logs as file"""
    from flask import request, send_file
    import os
    import tempfile

    source = request.args.get('source', 'nginx-access')
    lines = int(request.args.get('lines', 100))

    LOG_SOURCES = {
        'nginx-access': '/var/log/nginx/access.log',
        'nginx-error': '/var/log/nginx/error.log',
        'app': '/var/log/thinclient/app.log',
        'error': '/var/log/thinclient/error.log',
        'maintenance': '/var/log/thinclient/maintenance.log',
        'tftp': '/var/log/syslog',
        'system': '/var/log/syslog',
        'install': '/var/log/thinclient/installation.log',
        'build': '/var/log/thinclient/build.log',
        'boot-files': '/var/log/nginx/access.log'
    }

    log_file = LOG_SOURCES.get(source)

    if not log_file:
        return jsonify({'error': 'Invalid log source'}), 400

    # Special handling for installation/build logs (with timestamp in filename)
    if source in ['install', 'build']:
        import glob
        install_logs = glob.glob('/var/log/thinclient/thin-server-install-*.log')
        if install_logs:
            # Get the most recent installation log
            log_file = max(install_logs, key=os.path.getmtime)
        else:
            return jsonify({'error': 'No installation/build logs found'}), 404

    if not os.path.exists(log_file):
        return jsonify({'error': 'Log file not found'}), 404

    try:
        # Read last N lines
        result = subprocess.run(
            ['tail', '-n', str(lines), log_file],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode != 0:
            return jsonify({'error': 'Failed to read log file'}), 500

        log_content = result.stdout

        # Filter for TFTP if needed
        if source == 'tftp':
            log_lines = [line for line in log_content.splitlines() if 'tftpd' in line.lower() or 'tftp' in line.lower()]
            log_content = '\n'.join(log_lines)

        # Filter for boot files
        elif source == 'boot-files':
            log_lines = [line for line in log_content.splitlines() if any(path in line for path in ['/kernels/', '/initrds/', '/boot/', '/api/boot/'])]
            log_content = '\n'.join(log_lines)

        # Create temporary file
        temp = tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.log')
        temp.write(log_content)
        temp.close()

        # Send file
        return send_file(
            temp.name,
            mimetype='text/plain',
            as_attachment=True,
            download_name=f'{source}.log'
        )

    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Timeout reading log file'}), 500
    except Exception as e:
        return jsonify({'error': f'Error downloading logs: {str(e)}'}), 500


@api.route('/initramfs/build', methods=['POST'])
@login_required
def build_initramfs():
    """
    Build initramfs variants

    POST /api/initramfs/build
    {
        "variants": ["minimal", "intel", "vmware", "universal"]
    }

    Starts background build process and returns PID for monitoring
    """
    from flask import request
    import os

    try:
        data = request.json or {}
        variants = data.get('variants', [])

        if not variants:
            return jsonify({'error': 'No variants specified'}), 400

        # Find build script
        script_paths = [
            '/opt/thin-server/scripts/build-initramfs-variants.sh',
            '/opt/thinclient-manager/scripts/build-initramfs-variants.sh',
            'scripts/build-initramfs-variants.sh'
        ]

        script = None
        for path in script_paths:
            if os.path.exists(path):
                script = path
                break

        if not script:
            return jsonify({
                'error': 'Build script not found',
                'searched': script_paths
            }), 404

        # Start build process in background
        env = os.environ.copy()
        env['BUILD_VARIANTS'] = ' '.join(variants)

        process = subprocess.Popen(
            ['/bin/bash', script],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )

        # Log build start
        from utils import log_audit
        log_audit('INITRAMFS_BUILD', f'Started build for variants: {", ".join(variants)}')

        return jsonify({
            'status': 'started',
            'pid': process.pid,
            'variants': variants,
            'script': script
        }), 202

    except Exception as e:
        current_app.logger.error(f"Build initramfs: {e}", exc_info=True)
        return jsonify({'error': str(e)}), 500