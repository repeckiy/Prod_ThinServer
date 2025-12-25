# Thin-Server ThinClient Manager v7.8.0

**Централізована система управління тонкими клієнтами з мережевим завантаженням (PXE/iPXE) для корпоративного середовища.**

---

## Зміст

1. [Огляд системи](#огляд-системи)
2. [Ключові можливості](#ключові-можливості)
3. [Архітектура](#архітектура)
4. [Технології](#технології)
5. [Структура проекту](#структура-проекту)
6. [Встановлення](#встановлення)
7. [Конфігурація](#конфігурація)
8. [API Reference](#api-reference)
9. [Веб-панель](#веб-панель)
10. [Безпека](#безпека)
11. [CLI інструменти](#cli-інструменти)
12. [Усунення проблем](#усунення-проблем)

---

## Огляд системи

Thin-Server ThinClient Manager - комплексне рішення для розгортання та управління тонкими клієнтами через PXE/iPXE мережеве завантаження.

### Що робить система:

- **Мережеве завантаження**: Клієнти завантажуються по мережі без локальних дисків (PXE/iPXE → Linux initramfs)
- **Централізоване управління**: Веб-панель для керування всіма клієнтами
- **Автоматичне RDP**: Підключення до Windows RDS сервера без конфігурації на клієнті
- **Індивідуальні налаштування**: Кожен клієнт має власні параметри (роздільна здатність, периферія, RDP credentials)
- **Безпека**: Шифрування паролів (Fernet + PBKDF2), одноразові boot tokens, audit log

---

## Ключові можливості

### Функціональність:
- UEFI/iPXE мережеве завантаження
- Автоматична реєстрація клієнтів по MAC-адресі
- FreeRDP 3.17.2 для RDP підключень
- Підтримка периферії: USB, звук (ALSA), принтери, clipboard, drives
- Multi-monitor support
- SSH доступ до клієнтів (Dropbear) для діагностики
- Веб-панель управління з Chart.js графіками
- RESTful API для автоматизації
- Real-time моніторинг (heartbeat, метрики CPU/RAM)
- Комплексна система логування (7 категорій)

### Характеристики:
- **Мінімальний RAM footprint**: ~100MB для клієнта
- **Швидке завантаження**: 15-30 секунд від PXE до RDP
- **Масштабованість**: Сотні клієнтів на одному сервері
- **Надійність**: Fail-fast philosophy при деплої

---

## Архітектура

```
┌─────────────────────────────────────────────────────────────────┐
│                      THIN-SERVER                                  │
│                                                                  │
│  ┌──────────┐   ┌────────────────┐   ┌───────────────────────┐  │
│  │  Nginx   │   │  Flask App     │   │     SQLite DB         │  │
│  │(Port 80) │◄──┤ (Port 5000)    │◄──┤  /opt/thinclient-     │  │
│  └────┬─────┘   │                │   │   manager/db/         │  │
│       │         │ - api/boot.py  │   │   clients.db          │  │
│       │         │ - api/clients  │   └───────────────────────┘  │
│       │         │ - api/logs     │                              │
│       │         │ - api/heartbeat│                              │
│       │         └────────────────┘                              │
│       │                                                          │
│  ┌────┴──────────────────────────────────────────────────────┐  │
│  │  Static Files (/var/www/thinclient/)                      │  │
│  │  ├── boot.ipxe              # iPXE chainload script       │  │
│  │  ├── kernels/vmlinuz        # Linux kernel                │  │
│  │  └── initrds/               # Initramfs варіанти          │  │
│  │      ├── initrd-minimal.img     (~45MB)                   │  │
│  │      ├── initrd-intel.img       (~110MB, i915 firmware)   │  │
│  │      ├── initrd-vmware.img      (~60MB, vmwgfx)           │  │
│  │      └── initrd-generic.img     (~45MB, universal)        │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │ TFTP Server (Port 69)         /srv/tftp/                │    │
│  │  └── efi64/bootx64.efi        # iPXE bootloader (UEFI)  │    │
│  └─────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
                          │
                          │ Network (PXE/TFTP/HTTP)
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│                    THIN CLIENT (PXE Boot)                         │
│                                                                   │
│  1. DHCP Request → IP + next-server (TFTP)                       │
│  2. TFTP Download → bootx64.efi (iPXE bootloader)                │
│  3. iPXE chainload → http://server/boot.ipxe                     │
│  4. Get config → GET /api/boot/{MAC}                             │
│  5. Download → vmlinuz + initrd-*.img                            │
│  6. Boot Linux → X.org + Openbox + FreeRDP                       │
│  7. Retrieve credentials → GET /api/boot/credentials/{token}     │
│  8. Auto-connect → RDP Server                                    │
│  9. Heartbeat → POST /api/heartbeat/{MAC} (кожні 10 сек)         │
└───────────────────────────────────────────────────────────────────┘
```

---

## Технології

### Backend:
| Компонент | Версія | Призначення |
|-----------|--------|-------------|
| Python | 3.11+ | Runtime |
| Flask | 3.0.0 | Веб-фреймворк |
| SQLAlchemy | 2.0.23 | ORM |
| SQLite | 3.x | База даних |
| Werkzeug | 3.0.1 | WSGI утиліти |
| Flask-Limiter | 3.5.0 | Rate limiting |
| cryptography | 41.0.7 | Шифрування паролів (Fernet) |
| pytz | 2024.1 | Часові зони (Europe/Kyiv) |
| Nginx | latest | Reverse proxy |

### Client OS (initramfs):
| Компонент | Версія | Призначення |
|-----------|--------|-------------|
| Linux Kernel | 6.1+ | Ядро (з Debian 12) |
| FreeRDP | 3.17.2 | RDP клієнт (compiled from source) |
| X.org | latest | Графічний сервер |
| Openbox | latest | Window manager |
| BusyBox | latest | Мінімальні утиліти |
| Dropbear | latest | SSH сервер (опціонально) |

### Frontend:
| Компонент | Призначення |
|-----------|-------------|
| HTML5 + Jinja2 | Шаблони |
| Vanilla JavaScript (ES6+) | Інтерактивність |
| CSS3 (inline) | Стилізація |
| Chart.js 4.4.0 | Графіки на dashboard |
| Font Awesome 6.4.0 | Іконки |

---

## Структура проекту

```
Prod_ThinServer/
├── app.py                    # Flask application (642 рядки)
├── config.py                 # Конфігурація, VERSION
├── models.py                 # SQLAlchemy моделі (580 рядків)
├── utils.py                  # Утиліти, валідація, boot script
├── cli.py                    # CLI інструмент (click)
├── config.env                # Змінні середовища
├── requirements.txt          # Python залежності
│
├── api/                      # REST API модулі
│   ├── __init__.py           # Blueprint registration
│   ├── auth.py               # Аутентифікація
│   ├── admins.py             # Управління адміністраторами
│   ├── boot.py               # Boot config + credentials (283 рядки)
│   ├── clients.py            # CRUD клієнтів (382 рядки)
│   ├── heartbeat.py          # Моніторинг клієнтів (241 рядок)
│   ├── logs.py               # Логи клієнтів (1337 рядків)
│   ├── server_logs.py        # Серверні логи
│   ├── stats.py              # Статистика
│   └── system.py             # Системні операції
│
├── templates/                # HTML шаблони (Jinja2)
│   ├── index.html            # Головна панель (2241 рядок)
│   ├── dashboard.html        # Dashboard зі статистикою
│   ├── logs.html             # Перегляд логів
│   ├── server_logs.html      # Серверні логи
│   ├── admin.html            # Адмін панель
│   ├── login.html            # Сторінка входу
│   ├── base.html             # Base template
│   └── errors/               # Сторінки помилок
│
├── modules/                  # Інсталяційні модулі (Bash)
│   ├── 01-core-system.sh     # Базові пакети + FreeRDP (~15 хв)
│   ├── 02-initramfs.sh       # Створення initramfs (~3 хв)
│   ├── 03-web-panel.sh       # Flask + Nginx (~30 сек)
│   ├── 04-boot-config.sh     # iPXE + TFTP (~1 хв)
│   └── 05-maintenance.sh     # Cron jobs, backup
│
├── scripts/                  # Допоміжні скрипти
│   ├── verify-installation.sh
│   ├── backup-db.sh
│   └── cleanup-old-boots.sh
│
├── systemd/                  # Systemd service files
│   └── thinclient-manager.service
│
├── etc/                      # Linux configs
│   ├── cron.d/thinclient-cleanup
│   └── logrotate.d/thinclient
│
├── install.sh                # Головний інсталятор
├── deploy.sh                 # Оркестратор деплою
└── common.sh                 # Спільні Bash функції
```

---

## Встановлення

### Системні вимоги:

| Параметр | Мінімум | Рекомендовано |
|----------|---------|---------------|
| OS | Debian 11+ | Debian 12 (bookworm) |
| CPU | 2 cores | 4+ cores |
| RAM | 2 GB | 4+ GB |
| Disk | 10 GB | 20+ GB |
| Network | 100 Mbps | 1 Gbps |

### Швидке встановлення:

```bash
# 1. Клонувати репозиторій
git clone <repository-url> /opt/thin-server
cd /opt/thin-server

# 2. Налаштувати конфігурацію
nano config.env
# Встановити: SERVER_IP, RDS_SERVER, NTP_SERVER

# 3. Запустити інсталяцію (потребує root)
sudo ./install.sh install

# 4. Після завершення (~20 хвилин)
# Відкрити веб-панель: http://<SERVER_IP>/
# Логін: admin / admin123
```

### Перевірка після встановлення:

```bash
# Статус сервісів
systemctl status thinclient-manager nginx tftpd-hpa

# Health check
curl http://localhost/health

# Логи
tail -f /var/log/thinclient/app.log
```

---

## Конфігурація

### config.env - Основні параметри:

```bash
# Мережа
SERVER_IP="172.18.39.57"           # IP Thin-Server сервера
RDS_SERVER="rds.example.local"     # RDP сервер (Windows RDS)
NTP_SERVER="172.18.39.2"           # NTP сервер

# Шляхи
APP_DIR="/opt/thinclient-manager"
WEB_ROOT="/var/www/thinclient"
TFTP_ROOT="/srv/tftp"
LOG_DIR="/var/log/thinclient"
DB_DIR="/opt/thinclient-manager/db"

# Версії
FREERDP_VERSION="3.17.2"
DEBIAN_VERSION="bookworm"

# Features
ENABLE_PRINT_SERVER=true
ENABLE_USB_REDIRECT=true
ENABLE_AUDIO=true
ENABLE_SSH=true

# Стиснення initramfs
COMPRESSION_ALGO="zstd"

# Безпека
DEFAULT_ADMIN_USER="admin"
DEFAULT_ADMIN_PASS="admin123"
SESSION_TIMEOUT_MINUTES=60
```

### config.py - Flask конфігурація:

```python
class Config:
    VERSION = '7.8.0'
    APP_NAME = 'Thin-Server ThinClient Manager'

    # Database
    DATABASE_PATH = '/opt/thinclient-manager/db/clients.db'
    SQLALCHEMY_DATABASE_URI = f'sqlite:///{DATABASE_PATH}'

    # Security
    SECRET_KEY = _get_or_generate_secret_key()  # Auto-generated
    PERMANENT_SESSION_LIFETIME = 86400  # 24 hours

    # Rate Limiting
    RATELIMIT_DEFAULT = '1000 per hour'
```

---

## API Reference

### Authentication

Всі API endpoints (крім `/api/boot/*` та `/api/client-log*`) потребують авторизації через сесію.

### Boot Endpoints (без авторизації)

| Method | Endpoint | Опис |
|--------|----------|------|
| GET | `/api/boot/<mac>` | Отримати iPXE boot script для клієнта |
| GET | `/api/boot/<mac>/test` | Тестовий boot script (без оновлення статистики) |
| GET | `/api/boot/credentials/<token>` | Отримати RDP credentials по boot token |

**Приклад відповіді `/api/boot/AA:BB:CC:DD:EE:FF`:**
```
#!ipxe
echo Thin-Server ThinClient v7.8.0
echo MAC: AA:BB:CC:DD:EE:FF
kernel http://172.18.39.57/kernels/vmlinuz init=/init rw serverip=172.18.39.57 ...
initrd http://172.18.39.57/initrds/initrd-minimal.img
boot
```

### Client Management

| Method | Endpoint | Опис |
|--------|----------|------|
| GET | `/api/clients` | Список всіх активних клієнтів |
| POST | `/api/clients` | Створити нового клієнта |
| GET | `/api/clients/<id>` | Отримати клієнта по ID |
| PUT | `/api/clients/<id>` | Оновити клієнта |
| DELETE | `/api/clients/<id>` | Видалити клієнта (soft delete) |
| GET | `/api/clients/stats` | Статистика клієнтів |
| POST | `/api/clients/bulk-update` | Масове оновлення |
| POST | `/api/clients/<id>/toggle/<feature>` | Перемкнути периферію |
| GET | `/api/clients/<id>/metrics` | Метрики клієнта (CPU, RAM) |

**Приклад створення клієнта:**
```json
POST /api/clients
{
    "mac": "AA:BB:CC:DD:EE:FF",
    "hostname": "tc-office-001",
    "location": "Офіс 101",
    "rdp_server": "rds.example.local",
    "rdp_domain": "DOMAIN",
    "rdp_username": "user",
    "rdp_password": "password",
    "sound_enabled": true,
    "printer_enabled": false,
    "usb_redirect": false,
    "clipboard_enabled": true
}
```

### Heartbeat & Metrics

| Method | Endpoint | Опис |
|--------|----------|------|
| POST/GET | `/api/heartbeat/<mac>` | Heartbeat від клієнта (оновлює статус online) |
| POST | `/api/metrics` | Метрики від клієнта (CPU, RAM, network) |
| POST | `/api/diagnostic/<mac>` | Діагностичний звіт |

### Client Logs

| Method | Endpoint | Опис |
|--------|----------|------|
| POST | `/api/client-log` | Надіслати лог від клієнта |
| POST | `/api/client-log/batch` | Batch логи (формат: `timestamp\|level\|message\|mac`) |
| GET | `/api/clients/<id>/logs` | Логи клієнта |
| GET | `/api/clients/<id>/logs/unified` | Unified логи (server + client) |
| POST | `/api/clients/<id>/logs/clear` | Очистити логи |
| GET | `/api/clients/<id>/logs/export` | Експорт логів (CSV/JSON) |

### System Logs

| Method | Endpoint | Опис |
|--------|----------|------|
| GET | `/api/logs/all` | Всі логи з фільтрацією |
| GET | `/api/logs/search` | Пошук по логах |
| GET | `/api/logs/categories` | Категорії логів зі статистикою |
| GET | `/api/logs/stats` | Статистика логів |
| GET | `/api/audit-logs` | Audit логи |

### Log Categories

| Категорія | Ключові слова |
|-----------|---------------|
| `xserver` | X server, Xorg, X11, display, screen |
| `freerdp` | RDP, FreeRDP, xfreerdp, connection |
| `network` | Network, DHCP, IP, ethernet, DNS |
| `ntp` | Time sync, NTP, ntpdate |
| `boot` | booting, initramfs, kernel, mount |
| `print` | Print server, p910nd, printer |
| `system` | system, error, ssh, audio, driver |

---

## Веб-панель

### Сторінки:

| URL | Шаблон | Опис |
|-----|--------|------|
| `/` | index.html | Головна панель з таблицею клієнтів |
| `/dashboard` | dashboard.html | Dashboard зі статистикою та графіками |
| `/logs` | logs.html | Перегляд системних логів |
| `/server-logs` | server_logs.html | Логи сервера |
| `/admin` | admin.html | Управління адміністраторами |
| `/login` | login.html | Сторінка входу |
| `/health` | - | Health check (JSON) |

### Функції головної панелі (index.html):

- **Таблиця клієнтів**: MAC, hostname, location, RDP server, status, last seen, boot count
- **Статуси**: 🟢 Online (heartbeat < 5 хв), 🟡 Booting, 🔴 Offline
- **Модальні вікна**:
  - Add Client - створення нового клієнта
  - Edit Client - редагування параметрів
  - View Logs - перегляд логів клієнта з фільтрами
  - Bulk Edit - масове редагування
- **Периферійні пристрої** (10 опцій): sound, printer, USB, clipboard, drives, compression, multimon, print_server, SSH, debug

### Dashboard (dashboard.html):

- **Статистика**: total/online/offline/booting клієнти
- **Графіки** (Chart.js):
  - Peripheral usage (bar chart)
  - Client status distribution (doughnut)
  - Log levels (bar chart)
- **Boot errors feed**: останні помилки завантаження

---

## Безпека

### 1. Шифрування RDP паролів

Паролі RDP шифруються за допомогою Fernet (AES-128-CBC) з ключем, похідним від SECRET_KEY через PBKDF2:

```python
# models.py
def encrypt_password(plain_text):
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b'thin-server-rdp-encryption-salt-v1',
        iterations=100000,
    )
    key = base64.urlsafe_b64encode(kdf.derive(Config.SECRET_KEY.encode()[:32]))
    cipher = Fernet(key)
    return cipher.encrypt(plain_text.encode()).decode('utf-8')
```

### 2. Boot Tokens

Замість передачі паролів в URL параметрах kernel, використовуються одноразові boot tokens:

1. При запиті `/api/boot/<mac>` генерується токен (дійсний 10 хвилин)
2. Клієнт отримує boot script з `boottoken=<token>` замість `rdppass=<password>`
3. Після завантаження клієнт запитує `/api/boot/credentials/<token>`
4. Сервер повертає credentials та анулює токен (one-time use)

### 3. Rate Limiting

| Endpoint | Ліміт |
|----------|-------|
| Global default | 1000 per hour |
| `/api/boot/*` | 100 per minute per IP |
| `/api/client-log*` | 60 per minute per MAC |

### 4. Security Headers

```python
# app.py
response.headers['X-Content-Type-Options'] = 'nosniff'
response.headers['X-Frame-Options'] = 'SAMEORIGIN'
response.headers['X-XSS-Protection'] = '1; mode=block'
response.headers['Content-Security-Policy'] = "default-src 'self'; ..."
```

### 5. Audit Logging

Всі адміністративні дії логуються в таблицю `audit_log`:
- LOGIN, LOGOUT, LOGIN_FAILED
- CLIENT_ADDED, CLIENT_UPDATED, CLIENT_DELETED
- FEATURE_TOGGLED, BULK_UPDATE
- LOGS_CLEARED, RATE_LIMIT_EXCEEDED

---

## CLI інструменти

### cli.py - Управління через командний рядок:

```bash
# Адміністратори
python cli.py admin create <username>    # Створити адміна
python cli.py admin list                 # Список адмінів
python cli.py admin delete <username>    # Видалити адміна
python cli.py admin password <username>  # Змінити пароль

# Клієнти
python cli.py client list                # Список клієнтів
python cli.py client add <mac>           # Додати клієнта
python cli.py client delete <mac>        # Видалити клієнта
python cli.py client info <mac>          # Інформація про клієнта

# Система
python cli.py stats                      # Системна статистика
python cli.py logs                       # Останні логи
```

### Flask CLI:

```bash
flask init_db      # Ініціалізація бази даних
flask create_admin # Створення адміна інтерактивно
```

---

## Моделі бази даних

### Client

| Поле | Тип | Опис |
|------|-----|------|
| id | Integer | Primary key |
| mac | String(17) | MAC адреса (unique, indexed) |
| hostname | String(50) | Ім'я клієнта |
| location | String(100) | Розташування |
| rdp_server | String(255) | RDP сервер |
| rdp_domain | String(100) | Домен |
| rdp_username | String(100) | Користувач RDP |
| _rdp_password_encrypted | String(512) | Зашифрований пароль |
| rdp_width, rdp_height | Integer | Роздільна здатність |
| sound_enabled | Boolean | Звук |
| printer_enabled | Boolean | Принтер RDP |
| usb_redirect | Boolean | USB редирект |
| clipboard_enabled | Boolean | Буфер обміну |
| drives_redirect | Boolean | Диски |
| compression_enabled | Boolean | Стиснення |
| multimon_enabled | Boolean | Мультимонітор |
| print_server_enabled | Boolean | p910nd (TCP 9100) |
| ssh_enabled | Boolean | SSH доступ |
| debug_mode | Boolean | Verbose logging |
| status | String(20) | offline/booting/online |
| boot_count | Integer | Кількість завантажень |
| last_boot | DateTime | Останнє завантаження |
| last_seen | DateTime | Останній heartbeat |
| last_ip | String(45) | Остання IP адреса |
| cpu_usage, mem_usage | Float | Метрики (від heartbeat) |
| boot_token | String(64) | Одноразовий токен |
| boot_token_expires | DateTime | Час закінчення токену |

### Admin

| Поле | Тип | Опис |
|------|-----|------|
| id | Integer | Primary key |
| username | String(50) | Логін (unique) |
| password_hash | String(255) | Werkzeug hash |
| email | String(100) | Email |
| is_active | Boolean | Активний |
| is_superuser | Boolean | Суперадмін |
| last_login | DateTime | Останній вхід |

### ClientLog

| Поле | Тип | Опис |
|------|-----|------|
| id | Integer | Primary key |
| client_id | Integer | FK → client.id |
| event_type | String(50) | INFO/WARN/ERROR |
| details | Text | Повідомлення |
| category | String(50) | xserver/freerdp/network/... |
| ip_address | String(45) | IP клієнта |
| timestamp | DateTime | Час події |

### AuditLog

| Поле | Тип | Опис |
|------|-----|------|
| id | Integer | Primary key |
| timestamp | DateTime | Час події |
| admin_username | String(50) | Хто виконав |
| action | String(100) | LOGIN/CLIENT_ADDED/... |
| details | Text | Деталі |
| ip_address | String(45) | IP адміна |

---

## Initramfs структура

```
initrd-*.img (gzip/zstd compressed cpio)
├── /init                        # Main init script
├── /bin/
│   ├── busybox                  # BusyBox utilities (~1MB)
│   └── sh, ls, cp, mv, ...      # Symlinks to busybox
├── /usr/bin/
│   ├── xfreerdp                 # FreeRDP 3.17.2 (~5MB)
│   └── X, xrandr, openbox       # X.org + WM
├── /usr/sbin/
│   └── dropbear                 # SSH server (~200KB)
├── /lib/modules/                # Kernel modules
│   ├── drivers/net/             # Network drivers
│   ├── drivers/gpu/drm/         # Video drivers
│   ├── drivers/usb/             # USB support
│   └── sound/                   # ALSA
├── /lib/x86_64-linux-gnu/       # Shared libraries (~50)
└── /etc/                        # Configuration
```

### Варіанти initramfs:

| Файл | Розмір | GPU драйвер |
|------|--------|-------------|
| initrd-minimal.img | ~45MB | modesetting (universal) |
| initrd-intel.img | ~110MB | i915 + firmware |
| initrd-vmware.img | ~60MB | vmwgfx |
| initrd-generic.img | ~45MB | modesetting |

---

## Усунення проблем

### Клієнт не завантажується

```bash
# Перевірити TFTP
systemctl status tftpd-hpa
ls -la /srv/tftp/efi64/

# Перевірити Nginx
nginx -t
curl -I http://localhost/kernels/vmlinuz

# Перевірити Flask
systemctl status thinclient-manager
curl http://localhost:5000/health
```

### Клієнт не підключається до RDP

```bash
# Перевірити логи клієнта
curl "http://localhost/api/clients/<id>/logs?hours=1"

# Перевірити boot script
curl http://localhost/api/boot/AA:BB:CC:DD:EE:FF

# Перевірити credentials endpoint
# (потрібен валідний boot token)
```

### Клієнт показує offline

```bash
# Перевірити heartbeat
grep heartbeat /var/log/thinclient/app.log

# Статус клієнтів оновлюється при:
# - last_seen > 5 хвилин → offline
# - status=booting && last_seen > 10 хвилин → offline
```

### Перезапуск сервісів

```bash
systemctl restart thinclient-manager
systemctl restart nginx
systemctl restart tftpd-hpa
```

### Логи

```bash
# Flask application
tail -f /var/log/thinclient/app.log
tail -f /var/log/thinclient/error.log

# Nginx
tail -f /var/log/nginx/thinclient/access.log
tail -f /var/log/nginx/thinclient/error.log

# TFTP
grep tftpd /var/log/syslog
```

---

## DHCP конфігурація

### ISC DHCP:

```bash
# /etc/dhcp/dhcpd.conf
subnet 192.168.1.0 netmask 255.255.255.0 {
    range 192.168.1.100 192.168.1.200;
    option routers 192.168.1.1;

    # PXE Boot
    next-server 192.168.1.10;              # Thin-Server IP
    filename "efi64/bootx64.efi";          # iPXE for UEFI
}
```

### dnsmasq:

```bash
# /etc/dnsmasq.conf
dhcp-range=192.168.1.100,192.168.1.200,12h
dhcp-boot=efi64/bootx64.efi
enable-tftp
tftp-root=/srv/tftp
dhcp-option=66,192.168.1.10
```

---

## Ліцензія

Thin-Server ThinClient Manager - internal project.

---

## Підтримка

- Логи: `/var/log/thinclient/`
- Health check: `http://<SERVER_IP>/health`
- Діагностика: `./scripts/verify-installation.sh`
