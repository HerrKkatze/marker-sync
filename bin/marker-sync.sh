#!/bin/bash
# ============================================================================
# marker-sync.sh — служба синхронизации шаблонов маркиратора
# ============================================================================

set -o pipefail

# ========================= КОНСТАНТЫ ========================================
readonly SCRIPT_NAME="marker-sync"
readonly CONFIG_FILE="/etc/marker-sync/config"
readonly CREDENTIALS_FILE="/etc/marker-sync/credentials"
readonly LOG_FILE="/var/log/marker-sync.log"

# ========================= ЛОГИРОВАНИЕ ======================================
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info()    { log "INFO"    "$@"; }
log_warning() { log "WARNING" "$@"; }
log_error()   { log "ERROR"   "$@"; }

# ========================= ЗАГРУЗКА КОНФИГА =================================
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Конфиг не найден: $CONFIG_FILE"
        return 1
    fi

    source "$CONFIG_FILE"

    for var in SERVER_IP SHARE_NAME REMOTE_DIR; do
        if [[ -z "${!var}" ]]; then
            log_error "В конфиге не задана переменная: $var"
            return 1
        fi
    done
    return 0
}

# ========================= ПРОВЕРКА БЕЗОПАСНОСТИ ============================
check_credentials_security() {
    if [[ ! -f "$CREDENTIALS_FILE" ]]; then
        log_error "Файл учётных данных не найден: $CREDENTIALS_FILE"
        return 1
    fi

    local perms
    perms=$(stat -c '%a' "$CREDENTIALS_FILE" 2>/dev/null)
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        log_error "НЕБЕЗОПАСНЫЕ ПРАВА на $CREDENTIALS_FILE: $perms"
        return 1
    fi
    return 0
}

# ========================= ПРОВЕРКА ДОСТУПНОСТИ СЕРВЕРА =====================
check_server() {
    log_info "Проверка доступности сервера $SERVER_IP..."
    if ping -c 1 -W 5 "$SERVER_IP" >/dev/null 2>&1; then
        log_info "Сервер доступен"
        return 0
    else
        log_warning "Сервер $SERVER_IP недоступен. Пропуск итерации."
        return 1
    fi
}

# ========================= МОНТИРОВАНИЕ =====================================
mount_share() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Шара уже смонтирована в $MOUNT_POINT"
        return 0
    fi

    mkdir -p "$MOUNT_POINT"
    log_info "Монтирование //$SERVER_IP/$SHARE_NAME в $MOUNT_POINT..."

    mount -t cifs "//$SERVER_IP/$SHARE_NAME" "$MOUNT_POINT" \
        -o "credentials=$CREDENTIALS_FILE,vers=2.0,ro" \
        2>>"$LOG_FILE"
    
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_info "✅ Шара успешно смонтирована (SMB 2.0, read-only)"
        return 0
    else
        log_error "❌ Не удалось смонтировать шара (код ошибки: $result)"
        dmesg | tail -5 >> "$LOG_FILE"
        return 1
    fi
}

unmount_share() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Отмонтирование $MOUNT_POINT..."
        umount "$MOUNT_POINT" 2>>"$LOG_FILE" && \
            log_info "Отмонтировано" || \
            log_warning "Не удалось отмонтировать"
    fi
}

# ========================= ХЭШИРОВАНИЕ ======================================
get_sha256() {
    local file="$1"
    if [[ -f "$file" ]]; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    else
        echo "NONE"
    fi
}

# ========================= АТОМАРНАЯ ЗАГРУЗКА ФАЙЛА =========================
atomic_copy() {
    local src="$1"
    local dst="$2"
    local expected_hash="$3"

    local dst_dir
    dst_dir=$(dirname "$dst")
    mkdir -p "$dst_dir" || { log_error "Не удалось создать $dst_dir"; return 1; }

    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/.sync.XXXXXX")

    if ! cp -f "$src" "$tmp_file" 2>>"$LOG_FILE"; then
        log_error "Ошибка копирования: $src → $tmp_file"
        rm -f "$tmp_file"
        return 1
    fi

    local actual_hash
    actual_hash=$(get_sha256 "$tmp_file")
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        log_error "Несовпадение хэша: $src"
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv -f "$tmp_file" "$dst" 2>>"$LOG_FILE"; then
        log_error "Ошибка mv: $tmp_file → $dst"
        rm -f "$tmp_file"
        return 1
    fi

    return 0
}

# ========================= ОСНОВНОЙ АЛГОРИТМ ================================
sync_files() {
    local source_dir="${MOUNT_POINT}/${REMOTE_DIR}"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Исходная директория не найдена: $source_dir"
        return 1
    fi

    mkdir -p "$TEMPLATES_DIR" "$TMP_DIR"

    local total=0 updated=0 new=0 unchanged=0 errors=0

    log_info "Сканирование $source_dir..."

    # ===== ЭТАП 1: Скачивание новых и обновлённых файлов =====
    while IFS= read -r -d '' src_file; do
        local rel_path="${src_file#${source_dir}/}"
        local dst_file="${TEMPLATES_DIR}/${rel_path}"

        ((total++))

        local src_hash
        src_hash=$(get_sha256 "$src_file")
        if [[ "$src_hash" == "NONE" ]]; then
            log_warning "Не удалось прочитать: $src_file"
            ((errors++))
            continue
        fi

        local dst_hash
        dst_hash=$(get_sha256 "$dst_file")

        if [[ "$src_hash" == "$dst_hash" ]]; then
            ((unchanged++))
            continue
        fi

        if [[ "$dst_hash" == "NONE" ]]; then
            log_info "НОВЫЙ файл: $rel_path"
            ((new++))
        else
            log_info "ОБНОВЛЕНИЕ: $rel_path"
            ((updated++))
        fi

        if ! atomic_copy "$src_file" "$dst_file" "$src_hash"; then
            ((errors++))
            log_error "Не удалось загрузить: $rel_path"
        fi

    done < <(find "$source_dir" -type f -print0 2>>"$LOG_FILE")

    log_info "=== ЭТАП 1 ЗАВЕРШЁН ==="
    log_info "Всего: $total | Без изменений: $unchanged | Новых: $new | Обновлено: $updated | Ошибок: $errors"

    # ===== ЭТАП 2: Удаление файлов, которых нет на сервере =====
    log_info "Проверка удалённых файлов..."
    
    local deleted=0
    while IFS= read -r -d '' local_file; do
        local rel_path="${local_file#${TEMPLATES_DIR}/}"
        local src_file="${source_dir}/${rel_path}"

        if [[ ! -f "$src_file" ]]; then
            log_info "УДАЛЕНИЕ: $rel_path (файл удалён на сервере)"
            rm -f "$local_file"
            ((deleted++))
        fi
    done < <(find "$TEMPLATES_DIR" -type f -print0 2>>"$LOG_FILE")

    find "$TEMPLATES_DIR" -type d -empty -delete 2>/dev/null

    log_info "=== ЭТАП 2 ЗАВЕРШЁН ==="
    log_info "Удалено файлов: $deleted"

    log_info "=== ИТОГИ СИНХРОНИЗАЦИИ ==="
    log_info "Новых: $new | Обновлено: $updated | Удалено: $deleted | Без изменений: $unchanged | Ошибок: $errors"

    [[ $errors -eq 0 ]]
}

# ========================= ТОЧКА ВХОДА ======================================
main() {
    log_info "========== СТАРТ =========="

    if ! load_config; then
        exit 1
    fi

    if ! check_credentials_security; then
        exit 1
    fi

    if ! check_server; then
        exit 0
    fi

    if ! mount_share; then
        exit 1
    fi

    trap unmount_share EXIT INT TERM

    local sync_result=0
    sync_files || sync_result=$?

    if [[ $sync_result -eq 0 ]]; then
        log_info "========== УСПЕШНО =========="
    else
        log_warning "========== С ОШИБКАМИ =========="
    fi

    exit $sync_result
}

main "$@"
