#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/common.sh"

MODULE_NAME="web-panel"
MODULE_VERSION="$APP_VERSION"

# Source file paths
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

log "═══════════════════════════════════════"
log "Installing: Web Panel v$MODULE_VERSION"
log "═══════════════════════════════════════"

# ============================================
# VALIDATE PYTHON ENVIRONMENT
# ============================================
validate_python_environment() {
    log "Validating Python environment..."

    local validation_ok=true

    #Check Python 3 exists
    log "  Checking Python installation..."
    if ! command -v python3 >/dev/null 2>&1; then
        error "    ✗ python3 not found"
        error "    Install: apt-get install python3"
        return 1
    fi

    local python_ver=$(python3 --version 2>&1 | awk '{print $2}')
    log "    Python version: $python_ver"

    #Check Python version (need 3.9+)
    local python_major=$(echo "$python_ver" | cut -d. -f1)
    local python_minor=$(echo "$python_ver" | cut -d. -f2)

    if [ "$python_major" -lt 3 ]; then
        error "    ✗ Python $python_ver too old (need 3.9+)"
        return 1
    fi

    if [ "$python_major" -eq 3 ] && [ "$python_minor" -lt 9 ]; then
        error "    ✗ Python $python_ver too old (need 3.9+)"
        return 1
    fi

    log "    ✓ Python $python_ver (compatible)"

    #Check pip3
    log "  Checking pip..."
    if ! command -v pip3 >/dev/null 2>&1; then
        error "    ✗ pip3 not found"
        error "    Install: apt-get install python3-pip"
        return 1
    fi

    local pip_ver=$(pip3 --version 2>&1 | awk '{print $2}')
    log "    pip version: $pip_ver"
    log "    ✓ pip3 available"

    #Check Python can import basic modules
    log "  Checking Python functionality..."
    if ! python3 -c "import sys, os, json" 2>/dev/null; then
        error "    ✗ Python cannot import basic modules"
        return 1
    fi
    log "    ✓ Python can import basic modules"

    #Check source files exist BEFORE attempting to install
    log "  Checking source files..."
    local required_files=(
        "$PROJECT_ROOT/app.py"
        "$PROJECT_ROOT/config.py"
        "$PROJECT_ROOT/models.py"
        "$PROJECT_ROOT/utils.py"
        "$PROJECT_ROOT/cli.py"
    )

    local missing_count=0
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            error "    ✗ Missing: $(basename $file)"
            ((missing_count++))
            validation_ok=false
        fi
    done

    if [ $missing_count -eq 0 ]; then
        log "    ✓ All ${#required_files[@]} source files present"
    else
        error "    ✗ Missing $missing_count source file(s)"
        return 1
    fi

    #Check API directory
    if [ ! -d "$PROJECT_ROOT/api" ]; then
        error "    ✗ API directory not found: $PROJECT_ROOT/api"
        return 1
    fi

    local api_count=$(find "$PROJECT_ROOT/api" -name "*.py" | wc -l)
    if [ "$api_count" -lt 5 ]; then
        error "    ✗ API directory incomplete ($api_count files, expected 6+)"
        return 1
    fi
    log "    ✓ API directory present ($api_count files)"

    #Check templates directory
    if [ ! -d "$PROJECT_ROOT/templates" ]; then
        error "    ✗ Templates directory not found: $PROJECT_ROOT/templates"
        return 1
    fi

    local template_count=$(find "$PROJECT_ROOT/templates" -name "*.html" | wc -l)
    if [ "$template_count" -lt 5 ]; then
        error "    ✗ Templates directory incomplete ($template_count files, expected 10+)"
        return 1
    fi
    log "    ✓ Templates directory present ($template_count files)"

    log "✓ Python environment validation passed"
    log "  Python: $python_ver"
    log "  pip: $pip_ver"
    log "  Source files: ${#required_files[@]}"
    log "  API files: $api_count"
    log "  Templates: $template_count"

    return 0
}

# ============================================
# INSTALL PYTHON DEPENDENCIES
# ============================================
install_python_deps() {
    log "Installing Python dependencies..."

    #Install pip if missing
    log "  Checking pip installation..."
    if ! command -v pip3 &>/dev/null; then
        log "    Installing pip3..."
        if ! apt-get install -y python3-pip 2>&1 | tee -a "$LOG_FILE"; then
            error "    ✗ Failed to install pip3"
            return 1
        fi
        log "    ✓ pip3 installed"
    else
        local pip_ver=$(pip3 --version 2>&1 | awk '{print $2}')
        log "    pip3 already installed: v$pip_ver"
    fi

    #Upgrade pip
    log "  Upgrading pip..."
    local pip_before=$(pip3 --version 2>&1 | awk '{print $2}')

    if pip3 install --upgrade pip --break-system-packages 2>&1 | tee -a "$LOG_FILE" | grep -q "Successfully installed"; then
        local pip_after=$(pip3 --version 2>&1 | awk '{print $2}')
        if [ "$pip_before" != "$pip_after" ]; then
            log "    ✓ pip upgraded: $pip_before → $pip_after"
        else
            log "    ✓ pip already latest version: $pip_after"
        fi
    else
        log "    ⚠ pip upgrade had warnings, but continuing..."
    fi

    #Install Flask (CRITICAL)
    log "  Installing Flask..."
    local flask_install_log="/tmp/flask-install-$$.log"
    if pip3 install flask --break-system-packages > "$flask_install_log" 2>&1; then
        # Verify import
        if python3 -c "import flask" 2>/dev/null; then
            local flask_ver=$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)
            log "    ✓ Flask v$flask_ver installed and importable"
            cat "$flask_install_log" >> "$LOG_FILE"
            rm -f "$flask_install_log"
        else
            error "    ✗ Flask installed but CANNOT import - critical error"
            cat "$flask_install_log" >> "$LOG_FILE"
            rm -f "$flask_install_log"
            return 1
        fi
    else
        error "    ✗ Flask installation FAILED"
        error ""
        error "Last 30 lines of pip output:"
        tail -30 "$flask_install_log" | while IFS= read -r line; do
            error "    $line"
        done
        cat "$flask_install_log" >> "$LOG_FILE"
        rm -f "$flask_install_log"
        return 1
    fi

    #Install Flask-SQLAlchemy (CRITICAL)
    log "  Installing Flask-SQLAlchemy..."
    local sqlalchemy_install_log="/tmp/flask-sqlalchemy-install-$$.log"
    if pip3 install flask-sqlalchemy --break-system-packages > "$sqlalchemy_install_log" 2>&1; then
        # Verify import
        if python3 -c "import flask_sqlalchemy" 2>/dev/null; then
            local sqlalchemy_ver=$(python3 -c "import flask_sqlalchemy; print(flask_sqlalchemy.__version__)" 2>/dev/null)
            log "    ✓ Flask-SQLAlchemy v$sqlalchemy_ver installed and importable"
            cat "$sqlalchemy_install_log" >> "$LOG_FILE"
            rm -f "$sqlalchemy_install_log"
        else
            error "    ✗ Flask-SQLAlchemy installed but CANNOT import - critical error"
            cat "$sqlalchemy_install_log" >> "$LOG_FILE"
            rm -f "$sqlalchemy_install_log"
            return 1
        fi
    else
        error "    ✗ Flask-SQLAlchemy installation FAILED"
        error ""
        error "Last 30 lines of pip output:"
        tail -30 "$sqlalchemy_install_log" | while IFS= read -r line; do
            error "    $line"
        done
        cat "$sqlalchemy_install_log" >> "$LOG_FILE"
        rm -f "$sqlalchemy_install_log"
        return 1
    fi

    #Install Werkzeug (CRITICAL - needed for password hashing)
    # Note: Usually installed automatically with Flask, but verify
    log "  Checking Werkzeug..."
    if python3 -c "import werkzeug" 2>/dev/null; then
        local werkzeug_ver=$(python3 -c "import werkzeug; print(getattr(werkzeug, '__version__', 'installed'))" 2>/dev/null)
        log "    ✓ Werkzeug v$werkzeug_ver already installed (Flask dependency)"

        # Verify password hashing functionality
        if python3 -c "from werkzeug.security import generate_password_hash, check_password_hash; h = generate_password_hash('test'); assert check_password_hash(h, 'test')" 2>/dev/null; then
            log "    ✓ Werkzeug password hashing verified"
        else
            error "    ✗ Werkzeug password hashing FAILED"
            return 1
        fi
    else
        # Need to install separately
        log "  Installing Werkzeug..."
        local werkzeug_install_log="/tmp/werkzeug-install-$$.log"
        if pip3 install werkzeug --break-system-packages > "$werkzeug_install_log" 2>&1; then
            if python3 -c "import werkzeug" 2>/dev/null; then
                local werkzeug_ver=$(python3 -c "import werkzeug; print(werkzeug.__version__)" 2>/dev/null)
                log "    ✓ Werkzeug v$werkzeug_ver installed and importable"
                cat "$werkzeug_install_log" >> "$LOG_FILE"
                rm -f "$werkzeug_install_log"
            else
                error "    ✗ Werkzeug installed but CANNOT import"
                cat "$werkzeug_install_log" >> "$LOG_FILE"
                rm -f "$werkzeug_install_log"
                return 1
            fi
        else
            error "    ✗ Werkzeug installation FAILED"
            error ""
            error "Last 30 lines of pip output:"
            tail -30 "$werkzeug_install_log" | while IFS= read -r line; do
                error "    $line"
            done
            cat "$werkzeug_install_log" >> "$LOG_FILE"
            rm -f "$werkzeug_install_log"
            return 1
        fi
    fi

    #Install pytz (CRITICAL - needed for timezone handling)
    log "  Installing pytz..."
    local pytz_install_log="/tmp/pytz-install-$$.log"
    if pip3 install pytz --break-system-packages > "$pytz_install_log" 2>&1; then
        # Verify import and functionality
        if python3 -c "import pytz; tz = pytz.timezone('UTC')" 2>/dev/null; then
            local pytz_ver=$(python3 -c "import pytz; print(pytz.__version__)" 2>/dev/null)
            log "    ✓ pytz v$pytz_ver installed and importable"
            cat "$pytz_install_log" >> "$LOG_FILE"
            rm -f "$pytz_install_log"
        else
            error "    ✗ pytz installed but CANNOT import - critical error"
            cat "$pytz_install_log" >> "$LOG_FILE"
            rm -f "$pytz_install_log"
            return 1
        fi
    else
        error "    ✗ pytz installation FAILED"
        error ""
        error "Last 30 lines of pip output:"
        tail -30 "$pytz_install_log" | while IFS= read -r line; do
            error "    $line"
        done
        cat "$pytz_install_log" >> "$LOG_FILE"
        rm -f "$pytz_install_log"
        return 1
    fi

    #Install click (for CLI tools)
    log "  Installing click (CLI support)..."
    local click_install_log="/tmp/click-install-$$.log"
    if pip3 install click --break-system-packages > "$click_install_log" 2>&1; then
        # Verify import
        if python3 -c "import click" 2>/dev/null; then
            local click_ver=$(python3 -c "import click; print(click.__version__)" 2>/dev/null)
            log "    ✓ click v$click_ver installed and importable"
            cat "$click_install_log" >> "$LOG_FILE"
            rm -f "$click_install_log"
        else
            warn "    ⚠ click installed but CANNOT import - CLI might not work"
            cat "$click_install_log" >> "$LOG_FILE"
            rm -f "$click_install_log"
        fi
    else
        warn "    ⚠ click installation had issues - CLI might not work"
        tail -10 "$click_install_log" | while IFS= read -r line; do
            warn "      $line"
        done
        cat "$click_install_log" >> "$LOG_FILE"
        rm -f "$click_install_log"
    fi

    #Install cryptography (for secure operations)
    log "  Installing cryptography..."
    local crypto_install_log="/tmp/crypto-install-$$.log"
    if pip3 install cryptography --break-system-packages > "$crypto_install_log" 2>&1; then
        # Verify import
        if python3 -c "import cryptography" 2>/dev/null; then
            local crypto_ver=$(python3 -c "import cryptography; print(cryptography.__version__)" 2>/dev/null)
            log "    ✓ cryptography v$crypto_ver installed and importable"
            cat "$crypto_install_log" >> "$LOG_FILE"
            rm -f "$crypto_install_log"
        else
            warn "    ⚠ cryptography installed but CANNOT import"
            cat "$crypto_install_log" >> "$LOG_FILE"
            rm -f "$crypto_install_log"
        fi
    else
        warn "    ⚠ cryptography installation had issues"
        tail -10 "$crypto_install_log" | while IFS= read -r line; do
            warn "      $line"
        done
        cat "$crypto_install_log" >> "$LOG_FILE"
        rm -f "$crypto_install_log"
    fi

    #FINAL COMPREHENSIVE VERIFICATION
    log "  Running final dependency verification..."
    local verification_ok=true

    # Critical imports that MUST work
    local critical_imports=(
        "flask:Flask web framework"
        "flask_sqlalchemy:Flask-SQLAlchemy ORM"
        "werkzeug.security:Werkzeug security (password hashing)"
        "pytz:pytz timezone support"
    )

    for import_spec in "${critical_imports[@]}"; do
        local module_name="${import_spec%%:*}"
        local description="${import_spec#*:}"

        if ! python3 -c "import $module_name" 2>/dev/null; then
            error "    ✗ CRITICAL: Cannot import $module_name ($description)"
            verification_ok=false
        fi
    done

    if [ "$verification_ok" = false ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON DEPENDENCIES VERIFICATION FAILED    ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "One or more CRITICAL Python packages failed to install or import."
        error "The Flask web application WILL NOT WORK without these dependencies."
        error ""
        error "DO NOT PROCEED - Fix dependency installation first!"
        return 1
    fi

    log "✓ All Python dependencies installed and verified"
    log "  Flask: v$(python3 -c "import flask; print(flask.__version__)" 2>/dev/null)"
    log "  Flask-SQLAlchemy: v$(python3 -c "import flask_sqlalchemy; print(flask_sqlalchemy.__version__)" 2>/dev/null)"
    log "  Werkzeug: v$(python3 -c "import werkzeug; print(werkzeug.__version__)" 2>/dev/null)"
    log "  pytz: v$(python3 -c "import pytz; print(pytz.__version__)" 2>/dev/null)"

    return 0
}

# ============================================
# COPY PYTHON FILES
# ============================================
copy_python_files() {
    log "Copying Python application files..."

    ensure_dir "$APP_DIR" 755
    ensure_dir "$APP_DIR/api" 755

    local all_ok=true
    local files_copied=0
    local total_size=0

    #STEP 1: Validate syntax of all Python files BEFORE copying
    log "  Validating Python syntax..."

    local main_files=(app.py config.py models.py utils.py cli.py)
    local syntax_errors=0

    for file in "${main_files[@]}"; do
        if [ -f "$PROJECT_ROOT/$file" ]; then
            if python3 -m py_compile "$PROJECT_ROOT/$file" 2>/dev/null; then
                log "    ✓ $file syntax OK"
            else
                error "    ✗ $file has SYNTAX ERRORS"
                python3 -m py_compile "$PROJECT_ROOT/$file" 2>&1 | head -5
                ((syntax_errors++))
                all_ok=false
            fi
        else
            error "    ✗ $file not found"
            ((syntax_errors++))
            all_ok=false
        fi
    done

    # Validate API files syntax
    if [ -d "$PROJECT_ROOT/api" ]; then
        local api_files=$(find "$PROJECT_ROOT/api" -name "*.py" -type f)
        for file in $api_files; do
            if python3 -m py_compile "$file" 2>/dev/null; then
                log "    ✓ $(basename $file) syntax OK"
            else
                error "    ✗ $(basename $file) has SYNTAX ERRORS"
                ((syntax_errors++))
                all_ok=false
            fi
        done
    fi

    if [ "$syntax_errors" -gt 0 ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON SYNTAX VALIDATION FAILED            ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Found $syntax_errors Python file(s) with syntax errors."
        error "Flask application WILL NOT START with syntax errors."
        error ""
        error "DO NOT PROCEED - Fix syntax errors first!"
        return 1
    fi

    log "  ✓ All Python files have valid syntax"

    #STEP 2: Copy main application files
    log "  Copying main application files..."

    for file in "${main_files[@]}"; do
        if [ -f "$PROJECT_ROOT/$file" ]; then
            local file_size=$(stat -f%z "$PROJECT_ROOT/$file" 2>/dev/null || stat -c%s "$PROJECT_ROOT/$file" 2>/dev/null)
            local file_size_kb=$((file_size / 1024))

            if cp "$PROJECT_ROOT/$file" "$APP_DIR/" 2>/dev/null; then
                # Verify copied file
                if [ -f "$APP_DIR/$file" ]; then
                    local copied_size=$(stat -f%z "$APP_DIR/$file" 2>/dev/null || stat -c%s "$APP_DIR/$file" 2>/dev/null)

                    if [ "$file_size" -eq "$copied_size" ]; then
                        log "    ✓ $file (${file_size_kb} KB)"
                        ((files_copied++))
                        total_size=$((total_size + file_size))
                    else
                        error "    ✗ $file size mismatch (corrupted copy)"
                        all_ok=false
                    fi
                else
                    error "    ✗ $file not found after copy"
                    all_ok=false
                fi
            else
                error "    ✗ Failed to copy $file"
                all_ok=false
            fi
        else
            error "    ✗ $file not found in $PROJECT_ROOT"
            all_ok=false
        fi
    done

    #STEP 3: Copy API files
    log "  Copying API files..."

    if [ -d "$PROJECT_ROOT/api" ]; then
        local api_files_list=$(find "$PROJECT_ROOT/api" -name "*.py" -type f)
        local api_count=0
        local api_failed=0

        for source_file in $api_files_list; do
            local filename=$(basename "$source_file")
            local file_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null)

            if cp "$source_file" "$APP_DIR/api/" 2>/dev/null; then
                if [ -f "$APP_DIR/api/$filename" ]; then
                    local copied_size=$(stat -f%z "$APP_DIR/api/$filename" 2>/dev/null || stat -c%s "$APP_DIR/api/$filename" 2>/dev/null)

                    if [ "$file_size" -eq "$copied_size" ]; then
                        ((api_count++))
                        total_size=$((total_size + file_size))
                    else
                        error "    ✗ $filename size mismatch"
                        ((api_failed++))
                        all_ok=false
                    fi
                fi
            else
                error "    ✗ Failed to copy $filename"
                ((api_failed++))
                all_ok=false
            fi
        done

        if [ "$api_count" -gt 0 ]; then
            log "    ✓ API files copied: $api_count"
            files_copied=$((files_copied + api_count))
        fi

        if [ "$api_failed" -gt 0 ]; then
            error "    ✗ API files failed: $api_failed"
            all_ok=false
        fi
    else
        error "    ✗ API directory not found"
        all_ok=false
    fi

    #STEP 4: Set correct permissions
    log "  Setting file permissions..."
    chmod 644 "$APP_DIR"/*.py 2>/dev/null || true
    chmod 644 "$APP_DIR/api"/*.py 2>/dev/null || true
    log "    ✓ Permissions set (644)"

    #STEP 5: Verify all files can still be imported after copy
    log "  Verifying copied files can be imported..."

    cd "$APP_DIR" || {
        error "    ✗ Cannot change to $APP_DIR"
        return 1
    }

    for file in config.py models.py utils.py; do
        local module_name="${file%.py}"
        if python3 -c "import sys; sys.path.insert(0, '.'); import $module_name" 2>/dev/null; then
            log "    ✓ $module_name importable"
        else
            error "    ✗ $module_name CANNOT be imported"
            error "      This indicates a dependency or syntax issue"
            all_ok=false
        fi
    done

    cd - >/dev/null

    #FINAL VERIFICATION
    if [ "$all_ok" = false ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON FILES COPY FAILED                   ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Failed to copy or verify Python application files."
        error "The Flask application CANNOT run without these files."
        error ""
        error "DO NOT PROCEED - Fix file copy issues first!"
        return 1
    fi

    local total_size_kb=$((total_size / 1024))
    log "✓ Python files copied and verified"
    log "  Total files: $files_copied"
    log "  Total size: ${total_size_kb} KB"

    return 0
}

# ============================================
# INITIALIZE DATABASE
# ============================================
initialize_database() {
    log "Initializing database..."

    ensure_dir "$DB_DIR" 755

    #Remove old database if exists (clean start)
    if [ -f "$DB_DIR/clients.db" ]; then
        log "  Backing up existing database..."
        local backup_name="clients.db.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$DB_DIR/clients.db" "$DB_DIR/$backup_name" 2>/dev/null || true
        log "    ✓ Backup saved: $backup_name"
    fi

    cd "$APP_DIR" || {
        error "  ✗ Cannot change to $APP_DIR"
        return 1
    }

    log "  Loading configuration from config.env..."
    if [ -f "/opt/thin-server/config.env" ]; then
        # Export all variables from config.env for Python to access
        set -a  # Automatically export all variables
        source /opt/thin-server/config.env
        set +a  # Disable auto-export
        log "    ✓ Configuration loaded"
    else
        warn "    ! config.env not found at /opt/thin-server/config.env"
        warn "    Using default credentials: admin/admin123"
    fi

    #STEP 1: Initialize database with comprehensive validation
    log "  Creating database schema..."

    if python3 << 'PYCODE'
import sys
import os
sys.path.insert(0, '.')

# Disable Flask error logging during database init
os.environ['FLASK_ENV'] = 'production'

try:
    from app import app

    # Suppress Flask error logs
    import logging
    app.logger.setLevel(logging.CRITICAL)

    # Import models to register them
    with app.app_context():
        from app import db

        # Create all tables
        db.create_all()

        print("    ✓ Database schema created")

        # Verify tables exist
        from sqlalchemy import inspect
        inspector = inspect(db.engine)
        tables = inspector.get_table_names()

        expected_tables = {'admin', 'client', 'client_log', 'audit_log', 'system_settings'}
        missing = expected_tables - set(tables)

        if missing:
            print(f"    ✗ ERROR: Missing tables: {missing}")
            sys.exit(1)

        print(f"    ✓ Tables created: {', '.join(sorted(tables))}")

        # Verify table structures
        print("    Verifying table structures...")

        # Check 'client' table columns
        client_columns = [col['name'] for col in inspector.get_columns('client')]
        required_client_cols = ['id', 'mac', 'last_ip', 'hostname', 'status', 'last_seen']
        for col in required_client_cols:
            if col not in client_columns:
                print(f"    ✗ ERROR: Missing column '{col}' in 'client' table")
                sys.exit(1)
        print(f"    ✓ 'client' table has {len(client_columns)} columns")

        # Check 'admin' table columns
        admin_columns = [col['name'] for col in inspector.get_columns('admin')]
        required_admin_cols = ['id', 'username', 'password_hash']
        for col in required_admin_cols:
            if col not in admin_columns:
                print(f"    ✗ ERROR: Missing column '{col}' in 'admin' table")
                sys.exit(1)
        print(f"    ✓ 'admin' table has {len(admin_columns)} columns")

        # Check indexes
        indexes = inspector.get_indexes('client')
        print(f"    ✓ 'client' table has {len(indexes)} index(es)")

        # Create default admin if doesn't exist
        from app import Admin
        from werkzeug.security import generate_password_hash
        import os

        # Get credentials from environment (loaded from config.env)
        default_admin_user = os.environ.get('DEFAULT_ADMIN_USER', 'admin')
        default_admin_pass = os.environ.get('DEFAULT_ADMIN_PASS', 'admin123')

        admin = db.session.query(Admin).filter_by(username=default_admin_user).first()
        if not admin:
            admin = Admin(
                username=default_admin_user,
                password_hash=generate_password_hash(default_admin_pass),
                full_name='System Administrator',
                is_superuser=True
            )
            db.session.add(admin)
            db.session.commit()
            print(f"    ✓ Default admin user created (username: {default_admin_user})")
            if default_admin_pass in ['admin', 'admin123', 'password']:
                print("    ⚠ WEAK PASSWORD - change immediately!")
        else:
            print(f"    ✓ Admin user already exists ({default_admin_user})")

        # Verify admin was created
        admin_count = db.session.query(Admin).count()
        if admin_count < 1:
            print("    ✗ ERROR: No admin users in database")
            sys.exit(1)

        print(f"    ✓ Database has {admin_count} admin user(s)")

        # Don't call sys.exit(0) - let the script complete naturally
        # sys.exit(0) inside Flask app context causes error logs

except Exception as e:
    print(f"    ✗ ERROR: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYCODE
    then
        :  # Success
    else
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ DATABASE INITIALIZATION FAILED             ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Database schema creation or validation failed."
        error "The Flask application CANNOT function without a valid database."
        error ""
        error "Check the Python error output above for details."
        cd - > /dev/null
        return 1
    fi

    cd - > /dev/null

    #STEP 2: Verify database file exists and has correct size
    log "  Verifying database file..."

    if [ ! -f "$DB_DIR/clients.db" ]; then
        error "    ✗ Database file was not created: $DB_DIR/clients.db"
        return 1
    fi

    local db_size=$(stat -f%z "$DB_DIR/clients.db" 2>/dev/null || stat -c%s "$DB_DIR/clients.db" 2>/dev/null)
    local db_size_kb=$((db_size / 1024))

    if [ "$db_size" -lt 10240 ]; then  # Less than 10KB is suspicious
        error "    ✗ Database file too small ($db_size_kb KB) - may be corrupted"
        return 1
    fi

    log "    ✓ Database file exists (${db_size_kb} KB)"

    #STEP 3: Verify database integrity with SQLite
    log "  Running SQLite integrity check..."

    local integrity=$(sqlite3 "$DB_DIR/clients.db" "PRAGMA integrity_check;" 2>&1)
    if [ "$integrity" != "ok" ]; then
        error "    ✗ Database integrity check FAILED"
        error "      $integrity"
        return 1
    fi
    log "    ✓ Database integrity: OK"

    #STEP 4: Verify all expected tables exist
    log "  Verifying database tables..."

    local tables=$(sqlite3 "$DB_DIR/clients.db" ".tables" 2>/dev/null)
    local expected_tables=("client" "admin" "client_log" "audit_log" "system_settings")

    for table in "${expected_tables[@]}"; do
        if echo "$tables" | grep -q "$table"; then
            # Count columns in table
            local col_count=$(sqlite3 "$DB_DIR/clients.db" "PRAGMA table_info($table);" 2>/dev/null | wc -l)
            log "    ✓ Table '$table' ($col_count columns)"
        else
            error "    ✗ Table '$table' NOT FOUND"
            return 1
        fi
    done

    #STEP 5: Verify default admin user
    log "  Verifying default admin user..."

    local admin_count=$(sqlite3 "$DB_DIR/clients.db" "SELECT COUNT(*) FROM admin;" 2>/dev/null)
    if [ "$admin_count" -lt 1 ]; then
        error "    ✗ No admin users found in database"
        return 1
    fi

    local admin_username=$(sqlite3 "$DB_DIR/clients.db" "SELECT username FROM admin LIMIT 1;" 2>/dev/null)
    log "    ✓ Admin user exists: '$admin_username'"

    #STEP 6: Set correct permissions
    chmod 644 "$DB_DIR/clients.db"
    log "    ✓ Database permissions set (644)"

    log "✓ Database initialized and verified"
    log "  Location: $DB_DIR/clients.db"
    log "  Size: ${db_size_kb} KB"
    log "  Tables: ${#expected_tables[@]}"
    log "  Admin users: $admin_count"

    return 0
}
# ============================================
# COPY TEMPLATES
# ============================================
copy_templates() {
    log "Copying HTML templates..."

    ensure_dir "$APP_DIR/templates" 755
    ensure_dir "$APP_DIR/templates/errors" 755

    if [ ! -d "$PROJECT_ROOT/templates" ]; then
        error "  ✗ Templates directory not found: $PROJECT_ROOT/templates"
        return 1
    fi

    #Count source templates first
    local source_count=$(find "$PROJECT_ROOT/templates" -name "*.html" -type f | wc -l)
    log "  Found $source_count HTML template(s) in source"

    if [ "$source_count" -lt 5 ]; then
        error "  ✗ Too few templates in source ($source_count found, expected 10+)"
        return 1
    fi

    #Copy all templates recursively
    log "  Copying templates..."
    if ! cp -r "$PROJECT_ROOT/templates"/* "$APP_DIR/templates/" 2>/dev/null; then
        error "  ✗ Failed to copy templates"
        return 1
    fi

    #Verify critical templates exist
    log "  Verifying critical templates..."

    local critical_templates=(
        "base.html:Base template"
        "login.html:Login page"
        "index.html:Dashboard"
        "admin.html:Admin panel"
    )

    local templates_ok=true
    local templates_verified=0

    for template_spec in "${critical_templates[@]}"; do
        local template="${template_spec%%:*}"
        local description="${template_spec#*:}"

        if [ -f "$APP_DIR/templates/$template" ]; then
            local file_size=$(stat -f%z "$APP_DIR/templates/$template" 2>/dev/null || stat -c%s "$APP_DIR/templates/$template" 2>/dev/null)

            if [ "$file_size" -lt 100 ]; then  # Less than 100 bytes is suspicious
                error "    ✗ $template too small ($file_size bytes) - may be corrupted"
                templates_ok=false
            else
                log "    ✓ $template ($description)"
                ((templates_verified++))
            fi
        else
            error "    ✗ $template missing ($description)"
            templates_ok=false
        fi
    done

    #Check error templates
    log "  Verifying error templates..."

    if [ -d "$APP_DIR/templates/errors" ]; then
        local error_templates=$(find "$APP_DIR/templates/errors" -name "*.html" | wc -l)
        if [ "$error_templates" -gt 0 ]; then
            log "    ✓ Error templates ($error_templates file(s))"
        else
            warn "    ⚠ No error templates found"
        fi
    else
        warn "    ⚠ Error templates directory missing"
    fi

    #Count total copied templates
    local copied_count=$(find "$APP_DIR/templates" -name "*.html" -type f | wc -l)
    log "  Total templates copied: $copied_count"

    if [ "$copied_count" -lt "$source_count" ]; then
        error "  ✗ Template count mismatch (source: $source_count, copied: $copied_count)"
        templates_ok=false
    fi

    if [ "$templates_ok" = false ]; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ TEMPLATE COPY FAILED                       ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Critical HTML templates are missing or corrupted."
        error "The Flask web interface WILL NOT WORK without templates."
        error ""
        error "DO NOT PROCEED - Fix template issues first!"
        return 1
    fi

    log "✓ Templates copied and verified"
    log "  Critical templates: $templates_verified"
    log "  Total templates: $copied_count"

    return 0
}

# ============================================
# CREATE SYSTEMD SERVICE
# ============================================
create_systemd_service() {
    log "Creating systemd service..."
    
    cat > /etc/systemd/system/thinclient-manager.service << SERVICEUNIT
[Unit]
Description=Thin-Server ThinClient Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=/opt/thin-server/config.env
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/thinclient/app.log
StandardError=append:/var/log/thinclient/app.log

[Install]
WantedBy=multi-user.target
SERVICEUNIT
    
    systemctl daemon-reload
    systemctl enable thinclient-manager 2>&1 | tee -a "$LOG_FILE"
    
    # Stop if running
    systemctl stop thinclient-manager 2>/dev/null || true
    sleep 2
    
    # Start service
    systemctl start thinclient-manager
    
    # Wait and verify
    sleep 3
    
    if systemctl is-active --quiet thinclient-manager; then
        log "✓ Systemd service created and started"
        return 0
    else
        error "✗ Service failed to start"
        journalctl -u thinclient-manager -n 20 --no-pager
        return 1
    fi
}

# ============================================
# CONFIGURE NGINX
# ============================================
configure_nginx() {
    log "Configuring Nginx..."

    #STEP 1: Check if Nginx is installed
    log "  Checking Nginx installation..."

    # Check for nginx in PATH or /usr/sbin (Debian 12 location)
    local nginx_cmd=""
    if command -v nginx >/dev/null 2>&1; then
        nginx_cmd="nginx"
    elif [ -x /usr/sbin/nginx ]; then
        nginx_cmd="/usr/sbin/nginx"
    fi

    if [ -z "$nginx_cmd" ]; then
        error "    ✗ Nginx not found"
        error "    Run module 01-core-system first to install Nginx"
        return 1
    fi

    local nginx_ver=$($nginx_cmd -v 2>&1 | awk -F/ '{print $2}')
    log "    ✓ Nginx installed: v$nginx_ver"

    #STEP 2: Create log directories
    log "  Creating log directories..."

    ensure_dir "/var/log/nginx/thinclient" 755

    for logfile in access.log error.log boot-requests.log kernel-downloads.log initrd-downloads.log; do
        touch "/var/log/nginx/thinclient/$logfile"
        chmod 644 "/var/log/nginx/thinclient/$logfile"
    done

    log "    ✓ Log directories created"

    #STEP 3: Backup existing configuration
    if [ -f "/etc/nginx/sites-available/thinclient" ]; then
        log "  Backing up existing Nginx config..."
        local backup_name="thinclient.backup-$(date +%Y%m%d-%H%M%S)"
        cp "/etc/nginx/sites-available/thinclient" "/etc/nginx/sites-available/$backup_name"
        log "    ✓ Backup saved: $backup_name"
    fi

    #STEP 4: Create Nginx configuration
    log "  Creating Nginx configuration..."

    cat > /etc/nginx/sites-available/thinclient << 'NGINXCONF'
server {
    listen 80 default_server;
    server_name _;

    root /var/www/thinclient;

    #APACHE2-EQUIVALENT TIMEOUTS (from working production server)
    # Apache2 Timeout 300 = 5 minutes for send/receive operations
    # This allows slow/lossy network connections to complete large file downloads
    send_timeout 300s;
    client_body_timeout 300s;
    client_header_timeout 300s;

    # Apache2 KeepAlive settings
    keepalive_timeout 5s;
    keepalive_requests 100;

    # Detailed logging
    access_log /var/log/nginx/thinclient/access.log;
    error_log /var/log/nginx/thinclient/error.log;

    # Static files with specific logging
    location = /boot.ipxe {
        access_log /var/log/nginx/thinclient/boot-requests.log;
        try_files $uri =404;
    }

    location /kernels/ {
        access_log /var/log/nginx/thinclient/kernel-downloads.log;

        #CRITICAL FIX FOR iPXE: Re-enable sendfile but disable TCP_CORK
        # Apache2 uses APR_HAS_SENDFILE successfully on production
        # The issue is not sendfile itself but TCP_CORK (tcp_nopush)
        sendfile on;

        #DISABLE TCP_CORK - this is the key fix!
        # tcp_nopush causes nginx to wait for full packets with TCP_CORK
        # This can stall transfers to iPXE clients over slow/lossy connections
        # Apache2 (which works) doesn't use TCP_CORK by default
        tcp_nopush off;

        #Enable immediate packet sending (disable Nagle's algorithm)
        # Send data immediately without waiting, even if packets are small
        # Critical for iPXE clients with small TCP windows (1.5k-3k bytes)
        tcp_nodelay on;

        #Increase output buffers for large kernel files
        # Default is 1 32k - increase for better throughput
        output_buffers 4 64k;

        #Extended timeout for large kernel files over slow connections
        send_timeout 300s;

        try_files $uri =404;
    }

    location /initrds/ {
        access_log /var/log/nginx/thinclient/initrd-downloads.log;

        #Same iPXE-specific fixes for initrd files
        sendfile on;
        tcp_nopush off;
        tcp_nodelay on;
        output_buffers 4 64k;
        send_timeout 300s;

        try_files $uri =404;
    }

    location /drivers/ {
        try_files $uri =404;
    }

    # Flask application proxy
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Match Apache2 300s timeout
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Match Apache2 300s timeout
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
NGINXCONF

    if [ ! -f "/etc/nginx/sites-available/thinclient" ]; then
        error "    ✗ Failed to create Nginx config file"
        return 1
    fi

    local config_size=$(stat -f%z "/etc/nginx/sites-available/thinclient" 2>/dev/null || stat -c%s "/etc/nginx/sites-available/thinclient" 2>/dev/null)
    log "    ✓ Config file created (${config_size} bytes)"

    #STEP 5: Enable site
    log "  Enabling site configuration..."

    ln -sf /etc/nginx/sites-available/thinclient /etc/nginx/sites-enabled/thinclient

    # Remove default site if it exists
    if [ -L /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        log "    ✓ Default site disabled"
    fi

    log "    ✓ Site enabled: thinclient"

    #STEP 6: Test Nginx configuration BEFORE restarting
    log "  Testing Nginx configuration..."

    local test_output=$($nginx_cmd -t 2>&1)
    if echo "$test_output" | grep -q "syntax is ok" && echo "$test_output" | grep -q "test is successful"; then
        log "    ✓ Configuration syntax valid"
    else
        error "    ✗ Nginx configuration test FAILED"
        error "$test_output"
        return 1
    fi

    #STEP 7: Restart Nginx
    log "  Restarting Nginx..."

    if ! systemctl restart nginx 2>&1 | tee -a "$LOG_FILE"; then
        error "    ✗ Failed to restart Nginx"
        systemctl status nginx --no-pager || true
        journalctl -u nginx -n 20 --no-pager || true
        return 1
    fi

    log "    ✓ Nginx restarted"

    #STEP 8: Verify Nginx is actually running
    log "  Verifying Nginx status..."

    sleep 2

    if ! systemctl is-active --quiet nginx; then
        error "    ✗ Nginx is NOT running"
        systemctl status nginx --no-pager || true
        return 1
    fi

    log "    ✓ Nginx is running"

    #STEP 9: Test HTTP response (if curl available)
    if command -v curl >/dev/null 2>&1; then
        log "  Testing HTTP response..."

        # Give Flask app time to start
        sleep 3

        local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/ 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "401" ]; then
            log "    ✓ HTTP response: $http_code (OK)"
        else
            warn "    ⚠ HTTP response: $http_code (unexpected, but Nginx is running)"
        fi
    fi

    #STEP 10: Verify listening ports
    log "  Verifying listening ports..."

    if ss -tlnp 2>/dev/null | grep -q ":80.*nginx" || netstat -tlnp 2>/dev/null | grep -q ":80.*nginx"; then
        log "    ✓ Nginx listening on port 80"
    else
        error "    ✗ Nginx NOT listening on port 80"
        return 1
    fi

    log "✓ Nginx configured and verified"
    log "  Version: $nginx_ver"
    log "  Config: /etc/nginx/sites-available/thinclient"
    log "  Status: running"
    log "  Port: 80"

    return 0
}

# ============================================
# VERIFY INSTALLATION
# ============================================
verify_installation() {
    log ""
    log "Verifying web panel installation..."
    
    local ok=true
    
    # Check services
    for svc in nginx thinclient-manager; do
        if systemctl is-active --quiet "$svc"; then
            log "  ✓ $svc running"
        else
            error "  ✗ $svc NOT running"
            ok=false
        fi
    done
    
    # Check files
    for file in "$APP_DIR/app.py" "$APP_DIR/config.py" "$APP_DIR/models.py" "$APP_DIR/utils.py"; do
        if [ -f "$file" ]; then
            log "  ✓ $(basename $file)"
        else
            error "  ✗ $(basename $file) NOT FOUND"
            ok=false
        fi
    done
    
    # Check database
    if [ -f "$DB_DIR/clients.db" ]; then
        if sqlite3 "$DB_DIR/clients.db" ".tables" 2>/dev/null | grep -q "client"; then
            log "  ✓ Database with tables"
        else
            error "  ✗ Database has no tables"
            ok=false
        fi
    else
        error "  ✗ Database NOT FOUND"
        ok=false
    fi
    
    # Test Flask app response
    if command -v curl >/dev/null 2>&1; then
        log "  Testing Flask app..."
        sleep 2
        
        local response=$(curl -s http://127.0.0.1:5000/ 2>/dev/null || echo "")
        if [ -n "$response" ]; then
            log "  ✓ Flask app responding"
        else
            error "  ✗ Flask app not responding"
            ok=false
        fi
    fi
    
    if [ "$ok" = false ]; then
        error "✗ Web panel verification FAILED"
        return 1
    fi
    
    log "✓ Web panel verification passed"
    return 0
}

# ============================================
# MAIN
# ============================================
main() {
    #STEP 1: Check module dependencies
    log "Checking module dependencies..."

    if ! check_module_installed "core-system"; then
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ DEPENDENCY NOT MET                         ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Module 01-core-system must be installed first."
        error "Run: bash modules/01-core-system.sh"
        exit 1
    fi

    log "  ✓ Module 01-core-system installed"

    #STEP 2: Validate Python environment BEFORE starting
    log ""
    if ! validate_python_environment; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON ENVIRONMENT VALIDATION FAILED       ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Python environment is not ready for Flask installation."
        error "Please fix the issues above before proceeding."
        error ""
        error "DO NOT PROCEED - Fix Python environment first!"
        exit 1
    fi

    log ""
    log "═══════════════════════════════════════"
    log "Starting Web Panel Installation..."
    log "═══════════════════════════════════════"
    log ""

    #STEP 3: Install Python dependencies
    if ! install_python_deps; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON DEPENDENCIES INSTALLATION FAILED    ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""

    #STEP 4: Copy Python files
    if ! copy_python_files; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ PYTHON FILES COPY FAILED                   ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""

    #STEP 5: Initialize database
    if ! initialize_database; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ DATABASE INITIALIZATION FAILED             ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""

    #STEP 6: Copy templates
    if ! copy_templates; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ TEMPLATES COPY FAILED                      ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""

    #STEP 7: Create systemd service
    if ! create_systemd_service; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ SYSTEMD SERVICE CREATION FAILED            ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""

    #STEP 8: Configure Nginx
    if ! configure_nginx; then
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ NGINX CONFIGURATION FAILED                 ║"
        error "╚═══════════════════════════════════════════════╝"
        exit 1
    fi

    log ""
    log "═══════════════════════════════════════"
    log "Running Final Verification..."
    log "═══════════════════════════════════════"
    log ""

    #STEP 9: Final verification
    if verify_installation; then
        log ""
        log "╔═══════════════════════════════════════════════╗"
        log "║  ✓ WEB PANEL MODULE v$MODULE_VERSION COMPLETED         ║"
        log "╚═══════════════════════════════════════════════╝"
        log ""
        log "Web Panel is now installed and running!"
        log ""
        log "Access the admin panel:"
        log "  URL: http://$SERVER_IP/"
        log "  Username: admin"
        log "  Password: admin123"
        log ""
        log "IMPORTANT: Change the default password after first login!"
        log ""

        # Module installation completed successfully
        exit 0
    else
        error ""
        error "╔═══════════════════════════════════════════════╗"
        error "║  ✗ WEB PANEL VERIFICATION FAILED              ║"
        error "╚═══════════════════════════════════════════════╝"
        error ""
        error "Installation completed but verification failed."
        error "Check the errors above and verify manually."
        exit 1
    fi
}

main "$@"