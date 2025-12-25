#!/usr/bin/env python3
"""
Admin Management API Routes
"""

from flask import request, jsonify, session
from . import api
import models
from utils import login_required, log_audit, check_password_strength


@api.route('/admins', methods=['GET', 'POST'])
@login_required
def admins():
    """List or create admins"""
    
    # Get models
    model_classes = models.get_models()
    Admin = model_classes['Admin']
    db = model_classes['db']
    
    if request.method == 'POST':
        data = request.json
        username = data.get('username', '').strip()
        password = data.get('password', '')
        email = data.get('email', '').strip()
        
        if not username or not password:
            return jsonify({'error': 'Username and password required'}), 400
        
        # Check password strength
        is_strong, message = check_password_strength(password)
        if not is_strong:
            return jsonify({'error': message}), 400
        
        if Admin.query.filter_by(username=username).first():
            return jsonify({'error': 'Username already exists'}), 400
        
        admin = Admin(username=username, email=email)
        admin.set_password(password)
        db.session.add(admin)
        db.session.commit()
        
        log_audit('ADMIN_ADDED', f'New admin: {username}')
        return jsonify({
            'success': True,
            'admin': admin.to_dict()
        }), 201
    
    # GET - list all admins
    admins = Admin.query.all()
    return jsonify([a.to_dict() for a in admins])


@api.route('/admins/<int:admin_id>', methods=['GET', 'PUT', 'DELETE'])
@login_required
def admin_detail(admin_id):
    """Get, update, or delete an admin"""
    
    # Get models
    model_classes = models.get_models()
    Admin = model_classes['Admin']
    db = model_classes['db']
    
    admin = Admin.query.get_or_404(admin_id)
    
    if request.method == 'GET':
        return jsonify(admin.to_dict())
    
    elif request.method == 'PUT':
        data = request.json
        
        if 'email' in data:
            admin.email = data['email']
        
        if 'password' in data and data['password']:
            is_strong, message = check_password_strength(data['password'])
            if not is_strong:
                return jsonify({'error': message}), 400
            admin.set_password(data['password'])
        
        db.session.commit()
        
        log_audit('ADMIN_UPDATED', f'Admin: {admin.username}')
        return jsonify({
            'success': True,
            'admin': admin.to_dict()
        })
    
    elif request.method == 'DELETE':
        # Prevent deleting yourself
        if admin.id == session.get('admin_id'):
            return jsonify({'error': 'Cannot delete yourself'}), 400
        
        # Prevent deleting last admin
        if Admin.query.count() <= 1:
            return jsonify({'error': 'Cannot delete last admin'}), 400
        
        username = admin.username
        db.session.delete(admin)
        db.session.commit()
        
        log_audit('ADMIN_DELETED', f'Admin: {username}')
        return jsonify({'success': True})