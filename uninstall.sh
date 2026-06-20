#!/bin/bash
# ============================================================================
# uninstall.sh — безопасное удаление службы marker-sync (с сохранением шаблонов)
# ============================================================================
set -e

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

echo "🗑 Удаление службы marker-sync (с сохранением скачанных шаблонов)..."
echo ""

# ========================= 1. ОСТАНОВКА СЛУЖБЫ ==============================
echo "→ Остановка и отключение автозапуска..."
systemctl stop marker-sync.timer marker-sync.service 2>/dev/null || true
systemctl disable marker-sync.timer marker-sync.service 2>/dev/null || true
# Сбрасываем статус ошибок, если служба падала
systemctl reset-failed marker-sync.service 2>/dev/null || true
info "Служба остановлена"

# ========================= 2. ОТМОНТИРОВАНИЕ ШАРЫ ===========================
echo "→ Отмонтирование сетевой папки..."
if mountpoint -q /mnt/marker-share 2>/dev/null; then
    umount -f /mnt/marker-share 2>/dev/null || umount -l /mnt/marker-share 2>/dev/null || true
    info "Шара отмонтирована"
else
    info "Шара не была смонтирована"
fi

# ========================= 3. УДАЛЕНИЕ SYSTEMD ==============================
echo "→ Удаление systemd units..."
rm -f /etc/systemd/system/marker-sync.service
rm -f /etc/systemd/system/marker-sync.timer
systemctl daemon-reload
info "Systemd units удалены"

# ========================= 4. УДАЛЕНИЕ СКРИПТА И КОНФИГА ====================
echo "→ Удаление исполняемого файла и конфигурации..."
rm -f /usr/local/bin/marker-sync.sh
rm -rf /etc/marker-sync
info "Скрипт и конфиги удалены"

# ========================= 5. УДАЛЕНИЕ ЛОГОВ И TEMP =========================
echo "→ Очистка логов и временных файлов..."
rm -f /etc/logrotate.d/marker-sync
rm -f /var/log/marker-sync.log* /var/log/marker_sync.log*
rm -rf /tmp/marker-sync-tmp
info "Логи и временные файлы удалены"

# ========================= 6. ОЧИСТКА ПУСТЫХ ДИРЕКТОРИЙ =====================
echo "→ Удаление пустых директорий..."
# Удаляем точку монтирования, если она пуста
rmdir /mnt/marker-share 2>/dev/null || warn "Директория /mnt/marker-share не пуста, пропускаем"

# ========================= ИТОГ =============================================
echo ""
echo "============================================================"
info "СЛУЖБА ПОЛНОСТЬЮ УДАЛЕНА!"
echo "============================================================"
echo ""
warn "⚠️  ВАЖНО: Директория /var/lib/marker/templates НЕ БЫЛА УДАЛЕНА."
echo "   Все ранее скачанные и скопированные шаблоны сохранены."
echo ""
echo "   Если вы хотите удалить и их в будущем, выполните вручную:"
echo "   sudo rm -rf /var/lib/marker"
echo ""
