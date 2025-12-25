#!/usr/bin/env python3
"""
Authentication API Routes
"""

from flask import request, jsonify, session
from . import api
import models
from utils import log_audit


@api.route('/auth/login', methods=['POST'])
def login():
    """
    Admin login via API
    
    POST /api/auth/login
    Body: {username, password}
    """
    data = request.json
    username = data.get('username', '').strip()
    password = data.get('password', '')
    
    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400
    
    # Get models
    model_classes = models.get_models()
    Admin = model_classes['Admin']
    db = model_classes['db']
    
    admin = Admin.query.filter_by(username=username).first()
    if admin and admin.check_password(password):
        session.permanent = True
        session['admin_username'] = admin.username
        session['admin_id'] = admin.id
        admin.last_login = models.get_kyiv_time()
        db.session.commit()
        
        log_audit('API_LOGIN', f'Admin {admin.username} logged in via API')
        
        return jsonify({
            'success': True,
            'username': admin.username,
            'admin': admin.to_dict()
        })
    
    log_audit('API_LOGIN_FAILED', f'Failed login attempt for username: {username}')
    return jsonify({'error': 'Invalid credentials'}), 401


@api.route('/auth/logout', methods=['POST'])
def logout():
    """Admin logout via API"""
    admin_username = session.get('admin_username')
    session.clear()
    
    if admin_username:
        log_audit('API_LOGOUT', f'Admin {admin_username} logged out via API')
    
    return jsonify({'success': True, 'message': 'Logged out successfully'})


@api.route('/auth/check', methods=['GET'])
def check_auth():
    """Check authentication status"""
    if 'admin_username' in session:
        admin_id = session.get('admin_id')
        
        model_classes = models.get_models()
        Admin = model_classes['Admin']
        
        admin = Admin.query.get(admin_id)
        if admin:
            return jsonify({
                'authenticated': True,
                'username': admin.username,
                'admin': admin.to_dict()
            })
    
    return jsonify({'authenticated': False}), 401