#!/usr/bin/env python3
"""
Thin-Server Configuration
Central configuration for Flask application
This is the SINGLE SOURCE OF TRUTH for version number.
All other files should import and use Config.VERSION.
"""

import os
import secrets


def _get_or_generate_secret_key():
    """
    Get existing SECRET_KEY or generate new one

    Priority:
    1. Environment variable SECRET_KEY
    2. File /opt/thin-server/.secret_key
    3. Generate new random key and save to file
    """
    # Try environment variable first
    env_key = os.environ.get('SECRET_KEY')
    if env_key and env_key != 'thin-server-change-this-in-production':
        return env_key

    # Try file
    secret_file = '/opt/thin-server/.secret_key'
    if os.path.exists(secret_file):
        try:
            with open(secret_file, 'r') as f:
                key = f.read().strip()
                if key and len(key) >= 32:
                    return key
        except Exception as e:
            print(f"Warning: Could not read {secret_file}: {e}")

    # Generate new key
    new_key = secrets.token_hex(32)

    # Try to save (might fail if /opt/thin-server doesn't exist yet)
    try:
        os.makedirs('/opt/thin-server', mode=0o755, exist_ok=True)
        with open(secret_file, 'w') as f:
            f.write(new_key)
        os.chmod(secret_file, 0o600)
        print(f"Generated new SECRET_KEY and saved to {secret_file}")
    except Exception as e:
        print(f"Warning: Could not save SECRET_KEY to {secret_file}: {e}")
        print("SECRET_KEY will be regenerated on restart!")

    return new_key


class Config:
    """Flask configuration"""
    
    # ============================================
    # DIRECTORIES
    # ============================================
    BASE_DIR = '/opt/thinclient-manager'
    DB_DIR = os.path.join(BASE_DIR, 'db')
    LOG_DIR = '/var/log/thinclient'
    
    # ============================================
    # DATABASE
    # ============================================
    DATABASE_PATH = os.path.join(DB_DIR, 'clients.db')
    SQLALCHEMY_DATABASE_URI = f'sqlite:///{DATABASE_PATH}'
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    SQLALCHEMY_ENGINE_OPTIONS = {
        'pool_pre_ping': True,  # Verify connections before using
        'pool_recycle': 300,    # Recycle connections after 5 minutes
    }
    
    # ============================================
    # SECURITY
    # ============================================
    SECRET_KEY = _get_or_generate_secret_key()
    SESSION_COOKIE_SECURE = False  # Set True if using HTTPS (recommended)
    SESSION_COOKIE_HTTPONLY = True
    SESSION_COOKIE_SAMESITE = 'Lax'
    PERMANENT_SESSION_LIFETIME = 86400  # 24 hours
    
    # ============================================
    # APPLICATION
    # ============================================
    # ⚠️ SINGLE SOURCE OF TRUTH for version number
    # All other files should import Config.VERSION instead of hardcoding
    VERSION = '7.8.0'
    APP_NAME = 'Thin-Server ThinClient Manager'
    
    # ============================================
    # NETWORK CONFIG
    # ============================================
    # Read from environment (set by config.env during deployment)
    # For local development, set these in your shell or use localhost
    SERVER_IP = os.environ.get('SERVER_IP', '127.0.0.1')
    RDS_SERVER = os.environ.get('RDS_SERVER', 'localhost')
    NTP_SERVER = os.environ.get('NTP_SERVER', 'pool.ntp.org')
    
    # ============================================
    # LOGGING
    # ============================================
    LOG_LEVEL = 'INFO'
    LOG_FORMAT = '[%(asctime)s] %(levelname)s in %(module)s: %(message)s'
    
    # ============================================
    # RATE LIMITING (if Flask-Limiter installed)
    # ============================================
    RATELIMIT_ENABLED = True
    RATELIMIT_STORAGE_URL = 'memory://'
    RATELIMIT_DEFAULT = '1000 per hour'
    RATELIMIT_STRATEGY = 'fixed-window'
    
    # ============================================
    # BOOT CONFIG
    # ============================================
    BOOT_TIMEOUT = 300  # 5 minutes
    DEFAULT_RESOLUTION = '1920x1080'
    DEFAULT_VIDEO_DRIVER = 'modesetting'
    
    @staticmethod
    def init_app(app):
        """Initialize application"""
        # Ensure directories exist
        os.makedirs(Config.DB_DIR, mode=0o755, exist_ok=True)
        os.makedirs(Config.LOG_DIR, mode=0o755, exist_ok=True)