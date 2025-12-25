#!/usr/bin/env python3
"""
Thin-Server ThinClient Manager
Main Flask application
"""

from flask import Flask, render_template, request, redirect, url_for, session, flash, g, jsonify
from functools import wraps
import sys
import os
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime, timedelta
import time

# Add current directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import Config
from models import db, get_models, init_database, get_kyiv_time
from utils import log_audit, validate_mac


# ============================================
# LOGGING SETUP
# ============================================
def setup_logging(app):
    """Setup structured logging with rotation"""
    log_dir = Config.LOG_DIR
    os.makedirs(log_dir, mode=0o755, exist_ok=True)

    app.logger.handlers.clear()
    app.logger.setLevel(logging.DEBUG)

    # Format
    log_format = logging.Formatter(
        '[%(asctime)s] %(levelname)s in %(module)s:%(lineno)d: %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )

    # App log (INFO+)
    info_handler = RotatingFileHandler(
        os.path.join(log_dir, 'app.log'),
        maxBytes=10*1024*1024, backupCount=10
    )
    info_handler.setLevel(logging.INFO)
    info_handler.setFormatter(log_format)
    app.logger.addHandler(info_handler)

    # Error log (ERROR+)
    error_handler = RotatingFileHandler(
        os.path.join(log_dir, 'error.log'),
        maxBytes=10*1024*1024, backupCount=10
    )
    error_handler.setLevel(logging.ERROR)
    error_handler.setFormatter(log_format)
    app.logger.addHandler(error_handler)

    # Console
    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.DEBUG if app.debug else logging.WARNING)
    console.setFormatter(log_format)
    app.logger.addHandler(console)

    app.logger.info("="*60)
    app.logger.info(f"Thin-Server ThinClient Manager v{Config.VERSION}")
    app.logger.info(f"Logging configured: {log_dir}")
    app.logger.info("="*60)


# Initialize Flask app
app = Flask(__name__)
app.config.from_object(Config)
app.secret_key = Config.SECRET_KEY

# Setup logging
setup_logging(app)

# Initialize database
db.init_app(app)

# Get models
model_classes = get_models()
Client = model_classes['Client']
Admin = model_classes['Admin']
ClientLog = model_classes['ClientLog']
AuditLog = model_classes.get('AuditLog')

# ============================================
# RATE LIMITING
# ============================================
try:
    from flask_limiter import Limiter
    from flask_limiter.util import get_remote_address

    limiter = Limiter(
        app=app,
        key_func=get_remote_address,
        default_limits=["1000 per hour"],  # Global default
        storage_uri="memory://",
        strategy="fixed-window"
    )
    app.logger.info("✓ Flask-Limiter initialized")
except ImportError:
    app.logger.warning("Flask-Limiter not installed, rate limiting disabled")
    limiter = None

# ============================================
# BLUEPRINTS - API ROUTES
# ============================================
from api import api as api_blueprint
app.register_blueprint(api_blueprint, url_prefix='/api')

# Make limiter available to blueprints and apply boot endpoint limit
if limiter:
    app.limiter = limiter
    # Apply specific rate limit to boot endpoint (100 req/min per IP)
    # This will be applied when the blueprint is registered
    limiter.limit("100 per minute")(lambda: None)  # Dummy to test limiter works


# ============================================
# MIDDLEWARE - SECURITY & LOGGING
# ============================================
@app.after_request
def add_security_headers(response):
    """Add security headers to all responses"""
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'SAMEORIGIN'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    # Basic CSP
    csp = (
        "default-src 'self'; "
        "script-src 'self' 'unsafe-inline' 'unsafe-eval'; "
        "style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; "
        "connect-src 'self';"
    )
    response.headers['Content-Security-Policy'] = csp
    return response


@app.before_request
def log_request_info():
    """Log incoming request"""
    g.request_start_time = time.time()
    app.logger.info(
        f"{request.method} {request.path} from {request.remote_addr} "
        f"(User: {session.get('admin_username', 'Anonymous')})"
    )


@app.after_request
def log_response_info(response):
    """Log response with duration"""
    if hasattr(g, 'request_start_time'):
        duration = time.time() - g.request_start_time
        app.logger.info(
            f"{request.method} {request.path} -> {response.status_code} "
            f"({duration*1000:.2f}ms)"
        )
    return response


@app.teardown_appcontext
def shutdown_session(exception=None):
    """Cleanup database session"""
    if exception:
        app.logger.error(f"Request ended with exception: {exception}")
        db.session.rollback()
    db.session.remove()


# ============================================
# HEALTH CHECK
# ============================================
@app.route('/health')
def health_check():
    """Health check endpoint for monitoring"""
    health = {
        'status': 'ok',
        'version': Config.VERSION,
        'timestamp': get_kyiv_time().isoformat()
    }

    try:
        db.session.execute(db.text('SELECT 1'))
        health['database'] = 'ok'
        health['stats'] = {
            'total_clients': Client.query.filter_by(is_active=True).count(),
            'online_clients': Client.query.filter_by(is_active=True, status='online').count()
        }
    except Exception as e:
        app.logger.error(f"Health check DB error: {e}")
        health['database'] = 'error'
        health['status'] = 'degraded'

    status_code = 200 if health['status'] == 'ok' else 503
    return jsonify(health), status_code


# ============================================
# HELPER FUNCTIONS
# ============================================
def login_required(f):
    """Decorator for protected routes"""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'admin_id' not in session:
            app.logger.warning(
                f"Unauthorized access to {request.path} from {request.remote_addr}"
            )
            flash('Please login to access this page', 'warning')
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function


# ============================================
# ROUTES - AUTHENTICATION
# ============================================
@app.route('/login', methods=['GET', 'POST'])
def login():
    """Admin login page"""
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')

        if not username or not password:
            app.logger.warning(f"Empty login attempt from {request.remote_addr}")
            flash('Username and password required', 'error')
            return render_template('login.html')

        try:
            admin = Admin.query.filter_by(username=username, is_active=True).first()

            if admin and admin.check_password(password):
                session['admin_id'] = admin.id
                session['admin_username'] = admin.username
                session.permanent = True

                # Update last login
                admin.last_login = get_kyiv_time()
                db.session.commit()

                app.logger.info(f"Login: {admin.username} from {request.remote_addr}")
                log_audit('LOGIN', f'Admin {admin.username} logged in from {request.remote_addr}')
                flash(f'Welcome, {admin.username}!', 'success')
                return redirect(url_for('index'))
            else:
                app.logger.warning(f"Failed login for '{username}' from {request.remote_addr}")
                log_audit('LOGIN_FAILED', f'Failed login attempt for username: {username} from {request.remote_addr}')
                flash('Invalid credentials', 'error')

        except Exception as e:
            app.logger.error(f"Login error: {e}", exc_info=True)
            db.session.rollback()
            flash('Login error. Please try again.', 'error')

    return render_template('login.html')


@app.route('/logout')
def logout():
    """Admin logout"""
    admin_username = session.get('admin_username')
    session.clear()
    if admin_username:
        log_audit('LOGOUT', f'Admin {admin_username} logged out')
    return redirect(url_for('login'))


# ============================================
# ROUTES - MAIN PAGES
# ============================================
@app.route('/')
@login_required
def index():
    """Main dashboard"""
    try:
        # Update client statuses based on timeout before rendering
        from api.heartbeat import update_client_statuses
        update_client_statuses()

        clients = Client.query.filter_by(is_active=True)\
                              .order_by(Client.last_boot.desc().nullslast())\
                              .all()

        # Get current time with proper timezone
        now = get_kyiv_time()
        today_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        
        # Підрахунок статистики
        online_count = 0
        offline_count = 0
        booting_count = 0
        online_today_count = 0
        
        for c in clients:
            # Статус
            if c.status == 'online':
                online_count += 1
            elif c.status == 'booting':
                booting_count += 1
            else:
                offline_count += 1
            
            # Online today - безпечне порівняння
            if c.last_boot:
                # Переконатись що обидва мають timezone
                last_boot = c.last_boot
                if last_boot.tzinfo is None:
                    # Якщо naive, додати timezone
                    import pytz
                    last_boot = pytz.timezone('Europe/Kyiv').localize(last_boot)
                
                if last_boot >= today_start:
                    online_today_count += 1
        
        stats = {
            'total': len(clients),
            'online': online_count,
            'offline': offline_count,
            'booting': booting_count,
            'online_today': online_today_count,
            'server_ip': Config.SERVER_IP,
            'rds_server': Config.RDS_SERVER,
            'ntp_server': Config.NTP_SERVER
        }
        
        return render_template('index.html', clients=clients, stats=stats)

    except Exception as e:
        app.logger.error(f"Error in index route: {e}", exc_info=True)
        flash('Error loading dashboard', 'error')
        return render_template('errors/500.html', error=str(e)), 500


@app.route('/admin')
@login_required
def admin_panel():
    """Admin panel"""
    admins = Admin.query.all()

    # Get system stats
    stats = {
        'total_clients': Client.query.count(),
        'active_clients': Client.query.filter_by(is_active=True).count(),
        'total_boots': db.session.query(db.func.sum(Client.boot_count)).scalar() or 0,
        'total_logs': ClientLog.query.count()
    }

    return render_template('admin.html', admins=admins, stats=stats)


@app.route('/logs')
@login_required
def logs():
    """System logs view"""
    from datetime import timedelta

    page = request.args.get('page', 1, type=int)
    per_page = 100

    level = request.args.get('level', '')
    category = request.args.get('category', '')
    mac = request.args.get('mac', '')
    search = request.args.get('search', '')

    # Build query
    query = ClientLog.query

    if level:
        query = query.filter(ClientLog.event_type == level.upper())
    if category:
        query = query.filter(ClientLog.category == category)
    if mac:
        # Find client by MAC
        client = Client.query.filter_by(mac=mac.upper()).first()
        if client:
            query = query.filter(ClientLog.client_id == client.id)
    if search:
        query = query.filter(ClientLog.details.like(f'%{search}%'))

    # Paginate
    query = query.order_by(ClientLog.timestamp.desc())
    total_count = query.count()
    total_pages = (total_count + per_page - 1) // per_page

    logs = query.offset((page - 1) * per_page).limit(per_page).all()

    return render_template('logs.html',
                           logs=logs,
                           page=page,
                           total_pages=total_pages,
                           total_count=total_count)


@app.route('/dashboard')
@login_required
def dashboard():
    """System dashboard with metrics"""
    return render_template('dashboard.html')


@app.route('/server-logs')
@login_required
def server_logs():
    """Server logs viewer"""
    return render_template('server_logs.html')


# NOTE: Add/Edit client functionality is handled via AJAX modals in index.html
# using API endpoints POST /api/clients and PUT /api/clients/<id>
# These routes are commented out as they are not used


@app.route('/client/<int:client_id>/delete', methods=['POST'])
@login_required
def delete_client(client_id):
    """Delete (deactivate) client"""
    client = Client.query.get_or_404(client_id)
    
    try:
        # Soft delete
        client.is_active = False
        db.session.commit()
        
        log_audit('CLIENT_DELETED', f'MAC: {client.mac}')
        flash(f'Client {client.mac} deactivated', 'success')
    
    except Exception as e:
        db.session.rollback()
        flash(f'Error deleting client: {str(e)}', 'error')
    
    return redirect(url_for('index'))


# ============================================
# ERROR HANDLERS
# ============================================
@app.errorhandler(403)
def forbidden(e):
    """Handle 403 Forbidden"""
    app.logger.warning(f"403 Forbidden: {request.path} from {request.remote_addr}")
    return render_template('errors/403.html'), 403


@app.errorhandler(404)
def not_found(e):
    """Handle 404 Not Found"""
    app.logger.info(f"404 Not Found: {request.path} from {request.remote_addr}")
    return render_template('errors/404.html'), 404


@app.errorhandler(500)
def internal_error(e):
    """Handle 500 Internal Server Error"""
    app.logger.error(f"500 Error: {e}", exc_info=True)
    db.session.rollback()
    return render_template('errors/500.html', error=str(e)), 500


@app.errorhandler(Exception)
def handle_exception(e):
    """Handle all unhandled exceptions"""
    app.logger.critical(f"Unhandled exception: {e}", exc_info=True)
    db.session.rollback()
    return render_template('errors/500.html', error='Unexpected error occurred'), 500


# ============================================
# CONTEXT PROCESSORS
# ============================================
@app.context_processor
def inject_globals():
    """Inject global variables into templates"""
    return {
        'app_name': Config.APP_NAME,
        'app_version': Config.VERSION,
        'current_user': session.get('admin_username', 'Guest'),
        'server_ip': Config.SERVER_IP,
        'rds_server': Config.RDS_SERVER
    }


# ============================================
# TEMPLATE FILTERS
# ============================================
@app.template_filter('datetime')
def format_datetime(value):
    """Format datetime for display"""
    if value is None:
        return 'Never'
    
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except:
            return value
    
    return value.strftime('%Y-%m-%d %H:%M:%S')


@app.template_filter('date')
def format_date(value):
    """Format date for display"""
    if value is None:
        return 'Never'
    
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except:
            return value
    
    return value.strftime('%Y-%m-%d')


@app.template_filter('time')
def format_time(value):
    """Format time for display"""
    if value is None:
        return 'Never'
    
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except:
            return value
    
    return value.strftime('%H:%M:%S')


@app.template_filter('ago')
def time_ago(value):
    """Show time ago (e.g. '5 minutes ago')"""
    if value is None:
        return 'Never'
    
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except:
            return value
    
    now = get_kyiv_time()
    
    # Make both timezone-aware
    if value.tzinfo is None:
        import pytz
        value = pytz.timezone('Europe/Kyiv').localize(value)
    
    diff = now - value
    
    if diff < timedelta(minutes=1):
        return 'Just now'
    elif diff < timedelta(hours=1):
        mins = int(diff.total_seconds() / 60)
        return f'{mins} minute{"s" if mins != 1 else ""} ago'
    elif diff < timedelta(days=1):
        hours = int(diff.total_seconds() / 3600)
        return f'{hours} hour{"s" if hours != 1 else ""} ago'
    elif diff < timedelta(days=7):
        days = diff.days
        return f'{days} day{"s" if days != 1 else ""} ago'
    else:
        return format_datetime(value)


# ============================================
# CLI COMMANDS
# ============================================
@app.cli.command()
def init_db():
    """Initialize database"""
    if init_database(app):
        print("✅ Database initialized successfully")
    else:
        print("❌ Database initialization failed")


@app.cli.command()
def create_admin():
    """Create admin user interactively"""
    username = input("Username: ").strip()
    password = input("Password: ").strip()
    
    if not username or not password:
        print("❌ Username and password required")
        return
    
    with app.app_context():
        # Check if exists
        existing = Admin.query.filter_by(username=username).first()
        if existing:
            print(f"❌ Admin '{username}' already exists")
            return
        
        # Create admin
        admin = Admin(username=username)
        admin.set_password(password)
        db.session.add(admin)
        db.session.commit()
        
        print(f"✅ Admin '{username}' created successfully")


# ============================================
# APPLICATION STARTUP
# ============================================
if __name__ == '__main__':
    print("=" * 60)
    print(f"🚀 Thin-Server ThinClient Manager v{Config.VERSION}")
    print("=" * 60)
    print(f"📂 Database: {Config.DATABASE_PATH}")
    print(f"📊 Server IP: {Config.SERVER_IP}")
    print(f"🔗 RDS Server: {Config.RDS_SERVER}")
    print(f"🕐 NTP Server: {Config.NTP_SERVER}")
    print(f"🌐 Access: http://{Config.SERVER_IP}")
    print(f"👤 Login: admin/admin123")
    print(f"📝 Logs: {Config.LOG_DIR}/app.log")
    print(f"🏥 Health: http://{Config.SERVER_IP}/health")
    print("=" * 60)

    # Initialize database
    if not init_database(app):
        app.logger.error("Database initialization failed")
        print("❌ Failed to initialize database")
        sys.exit(1)

    print("✅ Database initialized")
    print("✅ Logging configured (structured + rotation)")
    print("✅ Security headers enabled")
    print("✅ Health check endpoint: /health")
    print("=" * 60)
    print("")
    print("NOTE: In production, runs via systemd behind Nginx")
    print("      systemctl status thinclient-manager")
    print("")

    # Run application
    app.run(host='127.0.0.1', port=5000, debug=False)