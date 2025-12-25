#!/usr/bin/env python3
"""
Thin-Server API Module
Blueprint registration for all API routes
"""

from flask import Blueprint

# Create API blueprint
api = Blueprint('api', __name__)

# Import all route modules
# IMPORTANT: Import order matters - auth must be first
from . import auth
from . import clients
from . import admins
from . import logs
from . import server_logs
from . import boot
from . import heartbeat
from . import system
from . import stats