#!/bin/bash
# ============================================================================
# install.sh — установщик marker-sync (исправленная версия)
# ============================================================================
set -e

INSTALL_DIR="/opt/marker-sync"
CONFIG_DIR="/etc/marker-sync"
BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

# ========================= ПРОВЕРКА ROOT ====================================
if [[ $EUID -ne 0 ]]; then
    error "Запустите с правами root: sudo $0"
    exit 1
fi

# ========================= УДАЛЕНИЕ =========================================
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "🗑 Полное удаление marker-sync..."
    
    # 1. Останавливаем и отключаем автозапуск
    systemctl disable --now marker-sync.timer marker-sync.service 2>/dev/null || true
    
    # 2. Удаляем systemd-юниты
    rm -f "$SERVICE_DIR/marker-sync.service" "$SERVICE_DIR/marker-sync.timer"
    systemctl daemon-reload
    
    # 3. Удаляем скрипт
    rm -f "$BIN_DIR/marker-sync.sh"
    
    # 4. Удаляем конфигурацию
    rm -rf "$CONFIG_DIR"
    
    # 5. Удаляем данные (ОСТОРОЖНО!)
    rm -rf /var/lib/marker
    rm -rf /tmp/marker-sync-tmp
    
    # 6. Удаляем logrotate
    rm -f /etc/logrotate.d/marker-sync
    
    # 7. Удаляем логи
    rm -f /var/log/marker-sync.log*
    
    # 8. Отмонтируем шару
    umount /mnt/marker-share 2>/dev/null || true
    
    info "marker-sync полностью удалён"
    exit 0
fi

echo "📦 Установка marker-sync..."
echo ""

# ========================= ПРОВЕРКА ЗАВИСИМОСТЕЙ ============================
echo "→ Проверка зависимостей..."

MISSING_PKGS=()
command -v mount.cifs >/dev/null 2>&1 || MISSING_PKGS+=("cifs-utils")
command -v sha256sum >/dev/null 2>&1 || MISSING_PKGS+=("coreutils")
command -v ping >/dev/null 2>&1 || MISSING_PKGS+=("iputils-ping")
command -v bash >/dev/null 2>&1 || MISSING_PKGS+=("bash")

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    warn "Отсутствуют пакеты: ${MISSING_PKGS[*]}"
    if apt-get install -y "${MISSING_PKGS[@]}" 2>/dev/null; then
        info "Пакеты установлены"
    else
        error "Установите вручную: sudo apt-get install ${MISSING_PKGS[*]}"
        command -v mount.cifs >/dev/null 2>&1 || { error "Без cifs-utils работать не будет"; exit 1; }
    fi
else
    info "Все зависимости установлены"
fi

# ========================= СОЗДАНИЕ ДИРЕКТОРИЙ ==============================
echo ""
echo "→ Создание директорий..."
mkdir -p "$CONFIG_DIR"
mkdir -p /var/lib/marker/templates
mkdir -p /tmp/marker-sync-tmp
mkdir -p /mnt/marker-share
info "Директории созданы"

# ========================= КОНФИГУРАЦИЯ =====================================
echo ""
echo "→ Создание конфигурации..."

if [[ ! -f "$CONFIG_DIR/config" ]]; then
    if [[ -f "$INSTALL_DIR/config/config.example" ]]; then
        cp "$INSTALL_DIR/config/config.example" "$CONFIG_DIR/config"
    else
        cat > "$CONFIG_DIR/config" << 'CONF_EOF'
SERVER_IP="169.254.190.157"
SHARE_NAME="share"
REMOTE_DIR="123"
TEMPLATES_DIR="/var/lib/marker/templates"
TMP_DIR="/tmp/marker-sync-tmp"
MOUNT_POINT="/mnt/marker-share"
CONF_EOF
    fi
    warn "Создан $CONFIG_DIR/config — ОТРЕДАКТИРУЙТЕ ЕГО"
else
    info "Конфиг уже существует: $CONFIG_DIR/config"
fi

if [[ ! -f "$CONFIG_DIR/credentials" ]]; then
    if [[ -f "$INSTALL_DIR/config/credentials.example" ]]; then
        cp "$INSTALL_DIR/config/credentials.example" "$CONFIG_DIR/credentials"
    else
        cat > "$CONFIG_DIR/credentials" << 'CRED_EOF'
username=your_username
password=your_password
CRED_EOF
    fi
    chmod 600 "$CONFIG_DIR/credentials"
    chown root:root "$CONFIG_DIR/credentials"
    warn "Создан $CONFIG_DIR/credentials — ОТРЕДАКТИРУЙТЕ ЕГО"
else
    perms=$(stat -c '%a' "$CONFIG_DIR/credentials")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        warn "Исправляю права credentials на 600..."
        chmod 600 "$CONFIG_DIR/credentials"
    fi
    info "Credentials уже существует"
fi

# ========================= СКРИПТ СИНХРОНИЗАЦИИ =============================
echo ""
echo "→ Установка скрипта синхронизации..."

if [[ -f "$INSTALL_DIR/bin/marker-sync.sh" ]]; then
    cp "$INSTALL_DIR/bin/marker-sync.sh" "$BIN_DIR/marker-sync.sh"
    info "Скопирован из репозитория"
else
    warn "bin/marker-sync.sh не найден в репозитории!"
    warn "Создаю ПОЛНУЮ рабочую версию скрипта..."
    
    cat > "$BIN_DIR/marker-sync.sh" << 'SCRIPT_EOF'
#!/bin/bash
# marker-sync.sh — полная версия
set -o pipefail

readonly CONFIG_FILE="/etc/marker-sync/config"
readonly CREDENTIALS_FILE="/etc/marker-sync/credentials"
readonly LOG_FILE="/var/log/marker-sync.log"

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}
log_info()    { log "INFO"    "$@"; }
log_warning() { log "WARNING" "$@"; }
log_error()   { log "ERROR"   "$@"; }

# Загрузка конфига
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Конфиг не найден: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

for var in SERVER_IP SHARE_NAME REMOTE_DIR; do
    if [[ -z "${!var}" ]]; then
        log_error "В конфиге не задана переменная: $var"
        exit 1
    fi
done

# Проверка credentials
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    log_error "Файл credentials не найден"
    exit 1
fi
perms=$(stat -c '%a' "$CREDENTIALS_FILE" 2>/dev/null)
if [[ "$perms" != "600" && "$perms" != "400" ]]; then
    log_error "НЕБЕЗОПАСНЫЕ ПРАВА на credentials: $perms"
    exit 1
fi

# Проверка сервера
log_info "Проверка доступности сервера $SERVER_IP..."
if ! ping -c 1 -W 5 "$SERVER_IP" >/dev/null 2>&1; then
    log_warning "Сервер $SERVER_IP недоступен. Пропуск итерации."
    exit 0
fi
log_info "Сервер доступен"

# Монтирование (БЕЗ soft и timeo — они не работают в CIFS!)
mkdir -p "$MOUNT_POINT"
if ! mountpoint -q "$MOUNT_POINT"; then
    log_info "Монтирование //$SERVER_IP/$SHARE_NAME..."
    mount -t cifs "//$SERVER_IP/$SHARE_NAME" "$MOUNT_POINT" \
        -o "credentials=$CREDENTIALS_FILE,vers=2.0,ro" 2>>"$LOG_FILE"
    
    if [[ $? -ne 0 ]]; then
        log_error "Не удалось смонтировать"
        exit 1
    fi
    log_info "✅ Шара смонтирована (SMB 2.0, read-only)"
fi

trap 'umount "$MOUNT_POINT" 2>/dev/null' EXIT

# Синхронизация
source_dir="$MOUNT_POINT/$REMOTE_DIR"
mkdir -p "$TEMPLATES_DIR" "$TMP_DIR"

total=0; updated=0; new_files=0; unchanged=0; errors=0

log_info "Сканирование $source_dir..."

# ЭТАП 1: Скачивание новых и обновлённых
while IFS= read -r -d '' src_file; do
    rel_path="${src_file#$source_dir/}"
    dst_file="$TEMPLATES_DIR/$rel_path"
    ((total++))
    
    src_hash=$(sha256sum "$src_file" 2>/dev/null | awk '{print $1}')
    [[ -z "$src_hash" ]] && { ((errors++)); continue; }
    
    dst_hash="NONE"
    [[ -f "$dst_file" ]] && dst_hash=$(sha256sum "$dst_file" | awk '{print $1}')
    
    if [[ "$src_hash" == "$dst_hash" ]]; then
        ((unchanged++)); continue
    fi
    
    if [[ "$dst_hash" == "NONE" ]]; then
        log_info "НОВЫЙ: $rel_path"; ((new_files++))
    else
        log_info "ОБНОВЛЕНИЕ: $rel_path"; ((updated++))
    fi
    
    mkdir -p "$(dirname "$dst_file")"
    tmp_file=$(mktemp "$TMP_DIR/.sync.XXXXXX")
    
    if cp -f "$src_file" "$tmp_file" 2>>"$LOG_FILE"; then
        tmp_hash=$(sha256sum "$tmp_file" | awk '{print $1}')
        if [[ "$tmp_hash" == "$src_hash" ]]; then
            mv -f "$tmp_file" "$dst_file"
        else
            log_error "Несовпадение хэша: $rel_path"
            rm -f "$tmp_file"; ((errors++))
        fi
    else
        log_error "Ошибка копирования: $rel_path"
        rm -f "$tmp_file"; ((errors++))
    fi
done < <(find "$source_dir" -type f -print0 2>/dev/null)

log_info "ЭТАП 1: всего=$total без_изменений=$unchanged новых=$new_files обновлено=$updated ошибок=$errors"

# ЭТАП 2: Удаление файлов, которых нет на сервере
log_info "Проверка удалённых файлов..."
deleted=0
while IFS= read -r -d '' local_file; do
    rel_path="${local_file#$TEMPLATES_DIR/}"
    if [[ ! -f "$source_dir/$rel_path" ]]; then
        log_info "УДАЛЕНИЕ: $rel_path"
        rm -f "$local_file"
        ((deleted++))
    fi
done < <(find "$TEMPLATES_DIR" -type f -print0 2>/dev/null)

find "$TEMPLATES_DIR" -type d -empty -delete 2>/dev/null

log_info "=== ИТОГИ ==="
log_info "Новых: $new_files | Обновлено: $updated | Удалено: $deleted | Без изменений: $unchanged | Ошибок: $errors"
[[ $errors -eq 0 ]] && log_info "✅ Синхронизация успешна" || log_warning "⚠ Завершено с ошибками"
SCRIPT_EOF
    warn "Создана ПОЛНАЯ версия скрипта"
fi

chmod 755 "$BIN_DIR/marker-sync.sh"

# ВАЖНО: проверяем shebang (исправление ошибки pipefail)
first_line=$(head -1 "$BIN_DIR/marker-sync.sh")
if [[ "$first_line" != "#!/bin/bash" ]]; then
    sed -i '1s|^#!.*|#!/bin/bash|' "$BIN_DIR/marker-sync.sh"
    warn "Исправлен shebang на #!/bin/bash"
fi

info "Скрипт установлен: $BIN_DIR/marker-sync.sh"

# ========================= SYSTEMD UNITS ====================================
echo ""
echo "→ Установка systemd units..."

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd не найден!"
    exit 1
fi

# --- service ---
cat > "$SERVICE_DIR/marker-sync.service" << 'EOF'
[Unit]
Description=Marker templates synchronization service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root
PrivateTmp=no
TimeoutStartSec=60
TimeoutStopSec=30
Restart=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=marker-sync
ExecStart=/usr/local/bin/marker-sync.sh
NoNewPrivileges=true
EOF

# --- timer ---
cat > "$SERVICE_DIR/marker-sync.timer" << 'EOF'
[Unit]
Description=Run marker-sync every 2 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=2min
RandomizedDelaySec=10s
Persistent=true
Unit=marker-sync.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# ✅ АВТОЗАПУСК + НЕМЕДЛЕННЫЙ СТАРТ
systemctl enable marker-sync.timer
systemctl start marker-sync.timer

info "✅ Systemd units установлены и АКТИВИРОВАНЫ (автозапуск включён)"

# ========================= LOGROTATE (ПРАВИЛЬНЫЙ!) ==========================
echo ""
echo "→ Настройка logrotate..."

cat > /etc/logrotate.d/marker-sync << 'EOF'
/var/log/marker-sync.log /var/log/marker_sync.log {
    size 5M
    rotate 6
    nocompress
    missingok
    notifempty
    create 0644 root root
    
    lastaction
        cd /var/log
        files=$(ls -1 marker-sync.log.[0-9]* 2>/dev/null | grep -v '\.gz$' | sort -t. -k3 -n -r)
        count=$(echo "$files" | grep -c .)
        if [ "$count" -gt 3 ]; then
            to_compress=$(echo "$files" | head -n -3)
            for file in $to_compress; do
                [ -f "$file" ] && gzip -f "$file"
            done
        fi
    endscript
}
EOF
info "Logrotate настроен (3 несжатых + архив)"

# ========================= ИТОГ =============================================
echo ""
echo "============================================================"
info "УСТАНОВКА ЗАВЕРШЕНА!"
echo "============================================================"
echo ""
echo "📋 Следующие шаги:"
echo ""
echo "  1. Отредактируйте конфиг:"
echo "     sudo nano $CONFIG_DIR/config"
echo ""
echo "  2. Укажите учётные данные:"
echo "     sudo nano $CONFIG_DIR/credentials"
echo ""
echo "  3. Проверьте вручную:"
echo "     sudo $BIN_DIR/marker-sync.sh"
echo ""
echo "  4. Смотрите логи:"
echo "     sudo tail -f /var/log/marker-sync.log"
echo ""
echo "  5. Проверьте таймер (автозапуск каждые 2 мин):"
echo "     systemctl status marker-sync.timer"
echo "     systemctl list-timers marker-sync.timer"
echo ""
echo "🔐 Автозапуск ВКЛЮЧЁН — служба запустится автоматически при загрузке!"
