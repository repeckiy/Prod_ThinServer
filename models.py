#!/usr/bin/env python3
"""
Thin-Server Database Models
SQLAlchemy models for database tables
"""

from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import pytz
import base64
import os
import logging
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

logger = logging.getLogger(__name__)

db = SQLAlchemy()

# Kyiv timezone
KYIV_TZ = pytz.timezone('Europe/Kyiv')

# Encryption for sensitive data
_fernet_instance = None


def _get_fernet():
    """Get or create Fernet cipher for password encryption"""
    global _fernet_instance
    if _fernet_instance is None:
        from config import Config
        # Derive a 32-byte key from SECRET_KEY
        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=32,
            salt=b'thin-server-rdp-encryption-salt-v1',  # Static salt for deterministic key
            iterations=100000,
        )
        key = base64.urlsafe_b64encode(kdf.derive(Config.SECRET_KEY.encode()[:32]))
        _fernet_instance = Fernet(key)
    return _fernet_instance


def encrypt_password(plain_text):
    """Encrypt a password for storage"""
    if not plain_text:
        return None
    try:
        cipher = _get_fernet()
        return cipher.encrypt(plain_text.encode()).decode('utf-8')
    except Exception as e:
        logger.error(f"Failed to encrypt password: {e}", exc_info=True)
        return plain_text  # Fallback to plaintext (not ideal but prevents data loss)


def decrypt_password(encrypted_text):
    """Decrypt a stored password"""
    if not encrypted_text:
        return None
    try:
        cipher = _get_fernet()
        # Try to decrypt - if it fails, assume it's plaintext (legacy)
        return cipher.decrypt(encrypted_text.encode()).decode('utf-8')
    except Exception:
        # If decryption fails, it might be plaintext (legacy), return as-is
        return encrypted_text


def get_kyiv_time():
    """Get current time in Kyiv timezone"""
    return datetime.now(KYIV_TZ)


def get_models():
    """Return dictionary of all models for importing"""
    return {
        'db': db,
        'Client': Client,
        'Admin': Admin,
        'ClientLog': ClientLog,
        'AuditLog': AuditLog,
        'SystemSettings': SystemSettings
    }


# ============================================
# CLIENT MODEL
# ============================================
class Client(db.Model):
    """
    ThinClient model
    """
    
    __tablename__ = 'client'
    
    # Primary key
    id = db.Column(db.Integer, primary_key=True)
    
    # Network identification
    mac = db.Column(db.String(17), unique=True, nullable=False, index=True)
    hostname = db.Column(db.String(50))
    location = db.Column(db.String(100))
    
    # RDP configuration
    rdp_server = db.Column(db.String(255))  # RDP server hostname
    rdp_domain = db.Column(db.String(100))
    rdp_username = db.Column(db.String(100))
    _rdp_password_encrypted = db.Column('rdp_password', db.String(512))  # Encrypted storage
    
    # Display settings
    rdp_width = db.Column(db.Integer, default=1920)
    rdp_height = db.Column(db.Integer, default=1080)
    resolution = db.Column(db.String(20), default='1920x1080')  # Backup format

    # ============================================
    # PERIPHERAL DEVICES - FULL SUPPORT
    # ============================================

    # Audio/Video
    sound_enabled = db.Column(db.Boolean, default=True)
    video_driver = db.Column(db.String(50), default='modesetting')

    # Printers
    printer_enabled = db.Column(db.Boolean, default=False)  # RDP printer redirect
    print_server_enabled = db.Column(db.Boolean, default=False)  # p910nd TCP 9100

    # USB & Storage
    usb_redirect = db.Column(db.Boolean, default=False)
    drives_redirect = db.Column(db.Boolean, default=False)

    # Clipboard & Sharing
    clipboard_enabled = db.Column(db.Boolean, default=True)

    # Performance
    compression_enabled = db.Column(db.Boolean, default=True)
    multimon_enabled = db.Column(db.Boolean, default=False)

    # Diagnostics
    ssh_enabled = db.Column(db.Boolean, default=False)
    ssh_password = db.Column(db.String(64), default='thinclient2025')
    debug_mode = db.Column(db.Boolean, default=False)
    
    # Status tracking
    status = db.Column(db.String(20), default='offline')  # offline, booting, online
    boot_count = db.Column(db.Integer, default=0)
    last_boot = db.Column(db.DateTime(timezone=True), index=True)
    last_seen = db.Column(db.DateTime(timezone=True))
    last_ip = db.Column(db.String(45))  # IPv4 or IPv6

    # ============================================
    # REAL-TIME METRICS (updated by heartbeat)
    # ============================================
    cpu_usage = db.Column(db.Float)  # Current CPU usage %
    mem_usage = db.Column(db.Float)  # Current RAM usage %
    rx_bytes = db.Column(db.BigInteger, default=0)  # Received bytes
    tx_bytes = db.Column(db.BigInteger, default=0)  # Transmitted bytes
    uptime_seconds = db.Column(db.Integer, default=0)  # Uptime in seconds

    # Peripheral status (last known state from logs)
    last_sound_status = db.Column(db.Boolean)
    last_printer_status = db.Column(db.Boolean)
    last_usb_status = db.Column(db.Boolean)

    # Diagnostics
    last_diagnostic = db.Column(db.DateTime(timezone=True))
    network_drivers_loaded = db.Column(db.Integer)
    video_driver_active = db.Column(db.String(50))
    
    # Administrative
    is_active = db.Column(db.Boolean, default=True, index=True)
    notes = db.Column(db.Text)
    created_at = db.Column(db.DateTime(timezone=True), default=get_kyiv_time)
    updated_at = db.Column(db.DateTime(timezone=True), default=get_kyiv_time, onupdate=get_kyiv_time)

    # Boot token for secure credential retrieval
    boot_token = db.Column(db.String(64), index=True)  # One-time token for boot
    boot_token_expires = db.Column(db.DateTime(timezone=True))  # Token expiration
    
    # Relationships
    logs = db.relationship('ClientLog', backref='client', lazy='dynamic', cascade='all, delete-orphan')

    @property
    def rdp_password(self):
        """Get decrypted RDP password"""
        if self._rdp_password_encrypted:
            return decrypt_password(self._rdp_password_encrypted)
        return None

    @rdp_password.setter
    def rdp_password(self, plain_password):
        """Set RDP password (will be encrypted)"""
        if plain_password:
            self._rdp_password_encrypted = encrypt_password(plain_password)
        else:
            self._rdp_password_encrypted = None

    def generate_boot_token(self):
        """Generate a one-time boot token (valid for 10 minutes)"""
        import secrets
        from datetime import timedelta
        self.boot_token = secrets.token_urlsafe(32)
        self.boot_token_expires = get_kyiv_time() + timedelta(minutes=10)
        return self.boot_token

    def validate_boot_token(self, token):
        """Validate and consume a boot token"""
        if not self.boot_token or not token:
            return False
        if self.boot_token != token:
            return False

        # Ensure timezone-aware comparison
        if not self.boot_token_expires:
            return False

        # Make sure boot_token_expires is timezone-aware
        expires = self.boot_token_expires
        if expires.tzinfo is None:
            # If timezone-naive, assume it's in Kyiv timezone
            expires = KYIV_TZ.localize(expires)

        if get_kyiv_time() > expires:
            return False

        return True

    def consume_boot_token(self):
        """Consume (invalidate) the boot token after use"""
        self.boot_token = None
        self.boot_token_expires = None

    def to_dict(self, include_logs=False):
        """Convert client to dictionary"""
        data = {
            'id': self.id,
            'mac': self.mac,
            'hostname': self.hostname,
            'location': self.location,
            'rdp_server': self.rdp_server,
            'rdp_domain': self.rdp_domain,
            'rdp_username': self.rdp_username,
            'rdp_width': self.rdp_width,
            'rdp_height': self.rdp_height,
            'resolution': self.resolution,
            # Peripherals
            'sound_enabled': self.sound_enabled,
            'printer_enabled': self.printer_enabled,
            'usb_redirect': self.usb_redirect,
            'print_server_enabled': self.print_server_enabled,
            'clipboard_enabled': self.clipboard_enabled,
            'drives_redirect': self.drives_redirect,
            'compression_enabled': self.compression_enabled,
            'multimon_enabled': self.multimon_enabled,
            'video_driver': self.video_driver,
            'ssh_enabled': self.ssh_enabled,
            'debug_mode': self.debug_mode,
            # Status
            'status': self.status,
            'boot_count': self.boot_count,
            'last_boot': self.last_boot.isoformat() if self.last_boot else None,
            'last_seen': self.last_seen.isoformat() if self.last_seen else None,
            'last_ip': self.last_ip,
            'is_active': self.is_active,
            'notes': self.notes,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            # Real-time metrics
            'cpu_usage': self.cpu_usage,
            'mem_usage': self.mem_usage,
            'rx_bytes': self.rx_bytes,
            'tx_bytes': self.tx_bytes
        }

        if include_logs:
            data['logs'] = [log.to_dict() for log in self.logs.limit(50).all()]

        return data
    
    def __repr__(self):
        return f'<Client {self.mac} ({self.hostname or "unnamed"})>'


# ============================================
# ADMIN MODEL
# ============================================
class Admin(db.Model):
    """
    Administrator accounts
    """
    
    __tablename__ = 'admin'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(50), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    
    full_name = db.Column(db.String(100))
    email = db.Column(db.String(100), unique=True)
    
    is_active = db.Column(db.Boolean, default=True, index=True)
    is_superuser = db.Column(db.Boolean, default=False)
    
    last_login = db.Column(db.DateTime(timezone=True))
    created_at = db.Column(db.DateTime(timezone=True), default=get_kyiv_time)
    
    def set_password(self, password):
        """Set password hash"""
        from werkzeug.security import generate_password_hash
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        """Check password"""
        from werkzeug.security import check_password_hash
        return check_password_hash(self.password_hash, password)
    
    def to_dict(self):
        """Convert admin to dictionary"""
        return {
            'id': self.id,
            'username': self.username,
            'full_name': self.full_name,
            'email': self.email,
            'is_active': self.is_active,
            'is_superuser': self.is_superuser,
            'last_login': self.last_login.isoformat() if self.last_login else None,
            'created_at': self.created_at.isoformat() if self.created_at else None
        }
    
    def __repr__(self):
        return f'<Admin {self.username}>'


# ============================================
# CLIENT LOG MODEL
# ============================================
class ClientLog(db.Model):
    """
    Client boot and runtime logs
    """
    
    __tablename__ = 'client_log'
    
    id = db.Column(db.Integer, primary_key=True)
    client_id = db.Column(db.Integer, db.ForeignKey('client.id'), nullable=False, index=True)
    
    event_type = db.Column(db.String(50), index=True)  # INFO, WARN, ERROR
    details = db.Column(db.Text)  # Log message
    category = db.Column(db.String(50), index=True, default='other')  # xserver, freerdp, network, etc.
    ip_address = db.Column(db.String(45))

    timestamp = db.Column(db.DateTime(timezone=True), default=get_kyiv_time, index=True)
    
    # Aliases for compatibility
    @property
    def level(self):
        """Alias for event_type"""
        return self.event_type
    
    @property
    def message(self):
        """Alias for details"""
        return self.details
    
    def to_dict(self):
        """Convert log to dictionary"""
        return {
            'id': self.id,
            'client_id': self.client_id,
            'client_mac': self.client.mac if self.client else None,
            'event_type': self.event_type,
            'level': self.event_type,  # Alias
            'details': self.details,
            'message': self.details,  # Alias
            'category': self.category or 'other',  # Log category
            'ip_address': self.ip_address,
            'timestamp': self.timestamp.isoformat() if self.timestamp else None
        }
    
    def __repr__(self):
        return f'<ClientLog {self.id} [{self.event_type}] {self.details[:50]}>'


# ============================================
# AUDIT LOG MODEL
# ============================================
class AuditLog(db.Model):
    """
    Administrator action audit log
    """
    
    __tablename__ = 'audit_log'
    
    id = db.Column(db.Integer, primary_key=True)
    
    timestamp = db.Column(db.DateTime(timezone=True), default=get_kyiv_time, index=True)
    admin_username = db.Column(db.String(50), index=True)
    
    action = db.Column(db.String(100), index=True)  # LOGIN, LOGOUT, CLIENT_ADDED, etc.
    details = db.Column(db.Text)
    
    ip_address = db.Column(db.String(45))
    user_agent = db.Column(db.String(255))
    
    def to_dict(self):
        """Convert to dictionary"""
        return {
            'id': self.id,
            'timestamp': self.timestamp.isoformat() if self.timestamp else None,
            'admin_username': self.admin_username,
            'action': self.action,
            'details': self.details,
            'ip_address': self.ip_address,
            'user_agent': self.user_agent
        }
    
    def __repr__(self):
        return f'<AuditLog {self.action} by {self.admin_username}>'


# ============================================
# SYSTEM SETTINGS MODEL
# ============================================
class SystemSettings(db.Model):
    """
    System configuration settings (key-value store)
    """
    
    __tablename__ = 'system_settings'
    
    id = db.Column(db.Integer, primary_key=True)
    
    key = db.Column(db.String(100), unique=True, nullable=False, index=True)
    value = db.Column(db.Text)
    description = db.Column(db.String(255))
    
    updated_at = db.Column(db.DateTime(timezone=True), default=get_kyiv_time, onupdate=get_kyiv_time)
    
    def to_dict(self):
        """Convert to dictionary"""
        return {
            'id': self.id,
            'key': self.key,
            'value': self.value,
            'description': self.description,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None
        }
    
    @staticmethod
    def get_setting(key, default=None):
        """Get setting value by key"""
        setting = SystemSettings.query.filter_by(key=key).first()
        return setting.value if setting else default
    
    @staticmethod
    def set_setting(key, value, description=None):
        """Set or update setting"""
        setting = SystemSettings.query.filter_by(key=key).first()
        
        if setting:
            setting.value = value
            if description:
                setting.description = description
        else:
            setting = SystemSettings(key=key, value=value, description=description)
            db.session.add(setting)
        
        db.session.commit()
        return setting
    
    def __repr__(self):
        return f'<SystemSettings {self.key}={self.value}>'


# ============================================
# DATABASE INITIALIZATION
# ============================================
def init_database(app):
    """
    Initialize database with tables and default admin
    """
    with app.app_context():
        try:
            # Create all tables
            db.create_all()

            # ============================================
            # MIGRATION: Add category column to client_log
            # ============================================
            try:
                from sqlalchemy import inspect, text
                inspector = inspect(db.engine)
                columns = [col['name'] for col in inspector.get_columns('client_log')]

                if 'category' not in columns:
                    app.logger.info("Migrating: Adding 'category' column to client_log table...")
                    with db.engine.connect() as conn:
                        conn.execute(text("ALTER TABLE client_log ADD COLUMN category VARCHAR(50) DEFAULT 'other'"))
                        conn.execute(text("CREATE INDEX IF NOT EXISTS ix_client_log_category ON client_log(category)"))
                        conn.commit()
                    app.logger.info("Migration completed: category column added")
            except Exception as migration_error:
                app.logger.warning(f"Migration warning: {migration_error}")
                # Non-critical, continue initialization

            # ============================================
            # MIGRATION: Add peripheral fields to client table
            # ============================================
            try:
                from sqlalchemy import inspect, text
                inspector = inspect(db.engine)
                client_columns = [col['name'] for col in inspector.get_columns('client')]

                new_columns = {
                    'clipboard_enabled': 'INTEGER DEFAULT 1',
                    'drives_redirect': 'INTEGER DEFAULT 0',
                    'compression_enabled': 'INTEGER DEFAULT 1',
                    'multimon_enabled': 'INTEGER DEFAULT 0',
                    'ssh_enabled': 'INTEGER DEFAULT 0',
                    'ssh_password': 'VARCHAR(64) DEFAULT "thinclient2025"',
                    'debug_mode': 'INTEGER DEFAULT 0'
                }

                with db.engine.connect() as conn:
                    for col_name, col_type in new_columns.items():
                        if col_name not in client_columns:
                            app.logger.info(f"Adding column: {col_name}")
                            conn.execute(text(f"ALTER TABLE client ADD COLUMN {col_name} {col_type}"))
                            conn.commit()
                    app.logger.info("Peripheral fields migration completed")
            except Exception as migration_error:
                app.logger.warning(f"Peripheral migration warning: {migration_error}")
                # Non-critical, continue initialization

            # Get default admin credentials from environment (config.env)
            default_admin_user = os.environ.get('DEFAULT_ADMIN_USER', 'admin')
            default_admin_pass = os.environ.get('DEFAULT_ADMIN_PASS', 'admin123')

            # Check if default admin exists
            admin = Admin.query.filter_by(username=default_admin_user).first()

            if not admin:
                # Create default admin with credentials from config.env
                admin = Admin(username=default_admin_user)
                admin.set_password(default_admin_pass)
                db.session.add(admin)
                db.session.commit()
                app.logger.info(f"Default admin created: {default_admin_user}/{default_admin_pass}")

                # Only show warning if using weak default password
                if default_admin_pass in ['admin', 'admin123', 'password', '12345']:
                    app.logger.warning("WEAK PASSWORD DETECTED - CHANGE IMMEDIATELY!")
                else:
                    app.logger.info("Password loaded from config.env")
            else:
                app.logger.info(f"Admin account exists: {default_admin_user}")
            
            # Check/create default system settings
            default_settings = [
                ('maintenance_mode', 'false', 'System maintenance mode'),
                ('auto_cleanup_enabled', 'true', 'Automatic log cleanup'),
                ('log_retention_days', '7', 'Days to retain logs'),
                ('default_rdp_port', '3389', 'Default RDP port'),
                ('enable_notifications', 'false', 'Email notifications')
            ]
            
            for key, value, description in default_settings:
                if not SystemSettings.query.filter_by(key=key).first():
                    setting = SystemSettings(key=key, value=value, description=description)
                    db.session.add(setting)
            
            db.session.commit()

            app.logger.info("Database initialized successfully")
            return True

        except Exception as e:
            app.logger.error(f"Database initialization failed: {e}", exc_info=True)
            db.session.rollback()
            return False