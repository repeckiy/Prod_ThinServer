#!/bin/bash
# Thin-Server Cleanup Script
# Clean up old boot tokens and set offline status for inactive clients

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/thinclient/cleanup.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "Starting Thin-Server cleanup..."

# Run Python cleanup script
python3 << 'PYTHON_SCRIPT'
import sys
import os
from datetime import datetime, timedelta

# Add app directory to path
sys.path.insert(0, '/opt/thinclient-manager')

try:
    from models import db, get_models, get_kyiv_time
    from config import Config
    from flask import Flask

    # Create Flask app context
    app = Flask(__name__)
    app.config.from_object(Config)
    db.init_app(app)

    with app.app_context():
        model_classes = get_models()
        Client = model_classes['Client']

        now = get_kyiv_time()
        changes = 0

        # ============================================
        # 1. Clear expired boot tokens (older than 1 hour)
        # ============================================
        expire_time = now - timedelta(hours=1)

        expired_clients = Client.query.filter(
            Client.boot_token != None,
            Client.boot_token_expires < expire_time
        ).all()

        for client in expired_clients:
            client.boot_token = None
            client.boot_token_expires = None
            changes += 1

        if len(expired_clients) > 0:
            print(f"Cleared {len(expired_clients)} expired boot tokens")

        # ============================================
        # 2. Set offline status for inactive clients (no heartbeat for 10 minutes)
        # ============================================
        offline_time = now - timedelta(minutes=10)

        inactive_clients = Client.query.filter(
            Client.status == 'online',
            Client.last_seen < offline_time
        ).all()

        for client in inactive_clients:
            client.status = 'offline'
            changes += 1

        if len(inactive_clients) > 0:
            print(f"Set {len(inactive_clients)} clients to offline status")

        # ============================================
        # 3. Delete old client logs (older than 7 days)
        # ============================================
        ClientLog = model_classes['ClientLog']
        log_expire_time = now - timedelta(days=7)

        old_logs = ClientLog.query.filter(
            ClientLog.timestamp < log_expire_time
        ).delete(synchronize_session=False)

        if old_logs > 0:
            print(f"Deleted {old_logs} old client logs")
            changes += old_logs

        # Commit all changes
        db.session.commit()

        print(f"Cleanup completed: {changes} total changes at {now}")
        sys.exit(0)

except Exception as e:
    print(f"ERROR: Cleanup failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON_SCRIPT

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log "✓ Cleanup completed successfully"
else
    log "✗ Cleanup failed with exit code $EXIT_CODE"
fi

exit $EXIT_CODE
