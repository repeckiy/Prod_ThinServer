#!/usr/bin/env python3
"""
Thin-Server CLI Management Tool
Command-line interface for managing Thin-Server system
"""

import click
import sys
import os

# Add app directory to path
sys.path.insert(0, '/opt/thinclient-manager')

from app import app, db
from models import Admin, Client, ClientLog, AuditLog
from utils import validate_mac, get_system_stats


@click.group()
def cli():
    """Thin-Server ThinClient Management CLI"""
    pass


# ============================================
# ADMIN COMMANDS
# ============================================
@cli.group()
def admin():
    """Admin management commands"""
    pass


@admin.command('create')
@click.argument('username')
@click.option('--password', prompt=True, hide_input=True, confirmation_prompt=True)
@click.option('--email', default='')
def admin_create(username, password, email):
    """Create new admin user"""
    with app.app_context():
        if Admin.query.filter_by(username=username).first():
            click.echo(f"Error: Admin '{username}' already exists", err=True)
            sys.exit(1)
        
        admin = Admin(username=username, email=email)
        admin.set_password(password)
        db.session.add(admin)
        db.session.commit()
        
        click.echo(f"✓ Admin '{username}' created successfully")


@admin.command('list')
def admin_list():
    """List all admins"""
    with app.app_context():
        admins = Admin.query.all()
        
        if not admins:
            click.echo("No admins found")
            return
        
        click.echo("\nAdmins:")
        click.echo("-" * 60)
        for a in admins:
            last_login = a.last_login.strftime('%Y-%m-%d %H:%M') if a.last_login else 'Never'
            click.echo(f"  {a.username:20} {a.email:30} Last: {last_login}")


@admin.command('delete')
@click.argument('username')
@click.confirmation_option(prompt='Are you sure?')
def admin_delete(username):
    """Delete admin user"""
    with app.app_context():
        if Admin.query.count() == 1:
            click.echo("Error: Cannot delete last admin", err=True)
            sys.exit(1)
        
        admin = Admin.query.filter_by(username=username).first()
        if not admin:
            click.echo(f"Error: Admin '{username}' not found", err=True)
            sys.exit(1)
        
        db.session.delete(admin)
        db.session.commit()
        click.echo(f"✓ Admin '{username}' deleted")


@admin.command('password')
@click.argument('username')
@click.option('--password', prompt=True, hide_input=True, confirmation_prompt=True)
def admin_password(username, password):
    """Change admin password"""
    with app.app_context():
        admin = Admin.query.filter_by(username=username).first()
        if not admin:
            click.echo(f"Error: Admin '{username}' not found", err=True)
            sys.exit(1)
        
        admin.set_password(password)
        db.session.commit()
        click.echo(f"✓ Password changed for '{username}'")


# ============================================
# CLIENT COMMANDS
# ============================================
@cli.group()
def client():
    """Client management commands"""
    pass


@client.command('add')
@click.argument('mac')
@click.option('--location', default='')
@click.option('--hostname', default='')
@click.option('--server', default='rds.local')
def client_add(mac, location, hostname, server):
    """Add new thin client"""
    mac = validate_mac(mac)
    if not mac:
        click.echo("Error: Invalid MAC address", err=True)
        sys.exit(1)
    
    with app.app_context():
        if Client.query.filter_by(mac=mac).first():
            click.echo(f"Error: Client {mac} already exists", err=True)
            sys.exit(1)
        
        client = Client(
            mac=mac,
            hostname=hostname,
            location=location,
            rdp_server=server
        )
        db.session.add(client)
        db.session.commit()
        
        click.echo(f"✓ Client {mac} added successfully")


@client.command('list')
@click.option('--active/--all', default=True)
def client_list(active):
    """List all clients"""
    with app.app_context():
        query = Client.query
        if active:
            query = query.filter_by(is_active=True)
        
        clients = query.all()
        
        if not clients:
            click.echo("No clients found")
            return
        
        click.echo("\nClients:")
        click.echo("-" * 80)
        for c in clients:
            last_boot = c.last_boot.strftime('%Y-%m-%d %H:%M') if c.last_boot else 'Never'
            click.echo(f"  {c.mac:17} {c.hostname or '-':15} {c.location or '-':20} Boots: {c.boot_count:3} Last: {last_boot}")


@client.command('delete')
@click.argument('mac')
@click.confirmation_option(prompt='Are you sure?')
def client_delete(mac):
    """Delete thin client"""
    mac = validate_mac(mac)
    if not mac:
        click.echo("Error: Invalid MAC address", err=True)
        sys.exit(1)
    
    with app.app_context():
        client = Client.query.filter_by(mac=mac).first()
        if not client:
            click.echo(f"Error: Client {mac} not found", err=True)
            sys.exit(1)
        
        client.is_active = False
        db.session.commit()
        click.echo(f"✓ Client {mac} deleted")


@client.command('info')
@click.argument('mac')
def client_info(mac):
    """Show client information"""
    mac = validate_mac(mac)
    if not mac:
        click.echo("Error: Invalid MAC address", err=True)
        sys.exit(1)
    
    with app.app_context():
        client = Client.query.filter_by(mac=mac).first()
        if not client:
            click.echo(f"Error: Client {mac} not found", err=True)
            sys.exit(1)
        
        click.echo(f"\nClient Information:")
        click.echo(f"  MAC: {client.mac}")
        click.echo(f"  Hostname: {client.hostname or '-'}")
        click.echo(f"  Location: {client.location or '-'}")
        click.echo(f"  RDS Server: {client.rdp_server or '-'}")
        click.echo(f"  Boot Count: {client.boot_count or 0}")
        click.echo(f"  Last Boot: {client.last_boot or 'Never'}")
        click.echo(f"  Last IP: {client.last_ip or '-'}")
        click.echo(f"  Created: {client.created_at}")


# ============================================
# DATABASE COMMANDS
# ============================================
@cli.group()
def db_cmd():
    """Database management commands"""
    pass


@db_cmd.command('init')
def db_init():
    """Initialize database"""
    with app.app_context():
        db.create_all()
        click.echo("✓ Database initialized")


@db_cmd.command('reset')
@click.confirmation_option(prompt='This will delete all data. Are you sure?')
def db_reset():
    """Reset database (WARNING: deletes all data)"""
    with app.app_context():
        db.drop_all()
        db.create_all()
        
        # Create default admin
        admin = Admin(username='admin')
        admin.set_password('admin123')
        db.session.add(admin)
        db.session.commit()
        
        click.echo("✓ Database reset complete")
        click.echo("✓ Default admin created: admin/admin123")


@db_cmd.command('backup')
@click.argument('output', type=click.Path())
def db_backup(output):
    """Backup database"""
    import shutil
    
    db_path = '/opt/thinclient-manager/db/clients.db'
    
    if not os.path.exists(db_path):
        click.echo("Error: Database not found", err=True)
        sys.exit(1)
    
    shutil.copy2(db_path, output)
    click.echo(f"✓ Database backed up to {output}")


@db_cmd.command('stats')
def db_stats():
    """Show database statistics"""
    with app.app_context():
        stats = get_system_stats()
        
        click.echo("\nDatabase Statistics:")
        click.echo("-" * 40)
        click.echo(f"Clients:")
        click.echo(f"  Total: {stats['clients']['total']}")
        click.echo(f"  Online today: {stats['clients']['online_today']}")
        click.echo(f"  Online this week: {stats['clients']['online_week']}")
        click.echo(f"\nLogs:")
        click.echo(f"  Total: {stats['logs']['total']}")
        click.echo(f"  Today: {stats['logs']['today']}")
        click.echo(f"  Errors today: {stats['logs']['errors_today']}")
        click.echo(f"\nAudit:")
        click.echo(f"  Total: {stats['audit']['total']}")
        click.echo(f"  Today: {stats['audit']['today']}")


# ============================================
# SYSTEM COMMANDS
# ============================================
@cli.command()
def status():
    """Show system status"""
    import subprocess
    
    click.echo("\nThin-Server System Status")
    click.echo("=" * 40)
    
    # Check services
    services = ['nginx', 'tftpd-hpa', 'thinclient-manager']
    for service in services:
        result = subprocess.run(
            ['systemctl', 'is-active', service],
            capture_output=True,
            text=True
        )
        status = "✓ running" if result.returncode == 0 else "✗ stopped"
        click.echo(f"  {service:20} {status}")
    
    # Check database
    if os.path.exists('/opt/thinclient-manager/db/clients.db'):
        size = os.path.getsize('/opt/thinclient-manager/db/clients.db')
        click.echo(f"\n  Database: ✓ exists ({size // 1024} KB)")
    else:
        click.echo(f"\n  Database: ✗ not found")
    
    # Show stats
    with app.app_context():
        stats = get_system_stats()
        click.echo(f"\n  Clients: {stats['clients']['total']} total, {stats['clients']['online_today']} online today")


@cli.command()
def version():
    """Show version information"""
    from config import Config
    click.echo(f"Thin-Server ThinClient Manager v{Config.VERSION}")


if __name__ == '__main__':
    cli()