


# 🔄 marker-sync

Служба автоматической односторонней синхронизации файлов шаблонов маркировки
с Samba-сервера на планшет Raspberry Pi.

## 📋 Описание

Проект реализует подсистему синхронизации шаблонов маркиратора, которая:
- Автоматически обновляет файлы шаблонов с центрального Samba-сервера
- Работает в фоне как systemd-служба с таймером (каждые 2 минуты)
- Гарантирует целостность данных (атомарная запись)
- Защищает Flash-память SD-карты от износа
- Ведёт структурированный журнал с ротацией

## ✨ Возможности

- ✅ **Односторонняя синхронизация**: только Server → Client
- ✅ **Атомарная запись**: файлы скачиваются во временную папку, проверяются по SHA-256, затем переносятся через `mv`
- ✅ **Отказоустойчивость**: при обрыве сети существующие шаблоны не повреждаются
- ✅ **Защита Flash-памяти**: перезапись происходит только при реальном изменении файла
- ✅ **Безопасность**: учётные данные хранятся в отдельном файле с правами `600`
- ✅ **Логирование**: формат `[ГГГГ-ММ-ДД ЧЧ:ММ:СС] [УРОВЕНЬ] Сообщение`
- ✅ **Ротация логов**: 5 МБ, 3 несжатых лога + сжатые архивы старых
- ✅ **Удаление файлов**: если файл удалён на сервере — удаляется и локально
- ✅ **Таймауты**: 10–15 секунд на сетевые операции
- ✅ **Systemd timer**: автозапуск каждые 2 минуты

## 🏗️ Архитектура

```
[Samba-сервер] ──mount.cifs──▶ /mnt/marker-share (read-only)
                                      │
                                      ▼ (сравнение SHA-256)
                              /tmp/marker-sync-tmp/ (атомарная запись)
                                      │
                                      ▼ (mv)
                          /var/lib/marker/templates/ (рабочая папка)
```

## 📦 Требования

- **ОС**: Raspberry Pi OS / Raspbian (протестировано на Jessie, Bookworm)
- **Пакеты**: `cifs-utils`, `coreutils` (sha256sum), `bash`, `mount`
- **Права**: `root` для монтирования CIFS
- **Сеть**: доступ к Samba-серверу по SMB 2.0

## 📂 Структура проекта

```
marker-sync/
├── README.md                          # Документация (этот файл)
├── install.sh                         # Скрипт установки
├── bin/
│   └── marker-sync.sh                 # Основной скрипт синхронизации
├── systemd/
│   ├── marker-sync.service            # Unit-файл службы
│   └── marker-sync.timer              # Unit-файл таймера
├── logrotate/
│   └── marker-sync                    # Конфиг ротации логов
└── config/
    ├── config.example                 # Пример конфигурации
    └── credentials.example            # Пример учётных данных
```

### Пути после установки

| Путь | Назначение |
|------|-----------|
| `/usr/local/bin/marker-sync.sh` | Исполняемый скрипт |
| `/etc/marker-sync/config` | Конфигурация службы |
| `/etc/marker-sync/credentials` | Учётные данные Samba (права 600) |
| `/var/lib/marker/templates/` | Рабочая папка с шаблонами |
| `/tmp/marker-sync-tmp/` | Временная папка для атомарной загрузки |
| `/var/log/marker-sync.log` | Журнал работы |

---

## 🚀 Установка

### 1. Подготовка системы

```bash
sudo apt update
sudo apt install -y cifs-utils coreutils bash git
```

### 2. Получение проекта

**Вариант A: Из локальной папки**
```bash
cd /opt
sudo cp -r /path/to/marker-sync ./marker-sync
```

**Вариант B: Из сетевой папки (Samba)**
```bash
sudo mkdir -p /mnt/net-install
sudo mount -t cifs //SERVER_IP/Share /mnt/net-install \
    -o username=your_user,password=your_pass,vers=2.0
sudo cp -r /mnt/net-install/skript2 /opt/marker-sync
sudo umount /mnt/net-install
```

**Вариант C: Из Git-репозитория**
```bash
cd /opt
sudo git clone https://github.com/yourname/marker-sync.git
```

### 3. Запуск установщика

```bash
cd /opt/marker-sync
sudo chmod +x install.sh
sudo ./install.sh
```

Установщик:
- Проверит зависимости
- Создаст необходимые директории
- Скопирует скрипт в `/usr/local/bin/`
- Установит systemd-юниты
- Настроит logrotate

### 4. Настройка конфигурации

**Отредактируйте основной конфиг:**
```bash
sudo nano /etc/marker-sync/config
```

Пример содержимого:
```bash
SERVER_IP="169.254.190.157"       # IP Samba-сервера
SHARE_NAME="share"                 # Имя шары
REMOTE_DIR="123"                   # Подпапка на сервере
TEMPLATES_DIR="/var/lib/marker/templates"
TMP_DIR="/tmp/marker-sync-tmp"
MOUNT_POINT="/mnt/marker-share"
```

**Укажите учётные данные:**
```bash
sudo nano /etc/marker-sync/credentials
```

Содержимое:
```
username=your_username
password=your_password
```

**Проверьте права:**
```bash
sudo chmod 600 /etc/marker-sync/credentials
sudo chown root:root /etc/marker-sync/credentials
ls -l /etc/marker-sync/credentials
# Должно быть: -rw------- root root
```

---

## 🔧 Использование

### Ручной запуск

```bash
sudo /usr/local/bin/marker-sync.sh
```

### Просмотр логов в реальном времени

```bash
sudo tail -f /var/log/marker-sync.log
```

### Проверка статуса таймера

```bash
systemctl status marker-sync.timer
systemctl list-timers marker-sync.timer
```

### Ручный запуск службы

```bash
sudo systemctl start marker-sync.service
```

### Остановка таймера

```bash
sudo systemctl stop marker-sync.timer
```

### Включение/выключение автозапуска

```bash
sudo systemctl enable marker-sync.timer   # Включить
sudo systemctl disable marker-sync.timer  # Выключить
```

---

## 🗑️ Удаление

### Полное удаление

```bash
# 1. Остановить и отключить службу
sudo systemctl disable --now marker-sync.timer marker-sync.service

# 2. Удалить systemd-юниты
sudo rm -f /etc/systemd/system/marker-sync.service
sudo rm -f /etc/systemd/system/marker-sync.timer
sudo systemctl daemon-reload

# 3. Удалить скрипт
sudo rm -f /usr/local/bin/marker-sync.sh

# 4. Удалить конфигурацию
sudo rm -rf /etc/marker-sync

# 5. Удалить данные (ОСТОРОЖНО: удалит все шаблоны!)
sudo rm -rf /var/lib/marker

# 6. Удалить временные файлы
sudo rm -rf /tmp/marker-sync-tmp

# 7. Удалить logrotate-конфиг
sudo rm -f /etc/logrotate.d/marker-sync

# 8. Удалить логи
sudo rm -f /var/log/marker-sync.log*

# 9. Удалить исходный код проекта
sudo rm -rf /opt/marker-sync

# 10. Отмонтировать шару (если смонтирована)
sudo umount /mnt/marker-share 2>/dev/null

echo "✅ marker-sync полностью удалён"
```

### Удаление через установщик

```bash
cd /opt/marker-sync
sudo ./install.sh --uninstall
```


---

## 🔍 Проверка работы

### Диагностика

```bash
# 1. Проверка прав credentials
sudo ls -l /etc/marker-sync/credentials
# Должно быть: -rw------- (600)

# 2. Проверка отсутствия паролей в коде
grep -c "password=" /usr/local/bin/marker-sync.sh
# Должно быть: 0

# 3. Проверка доступности сервера
ping -c 3 169.254.190.157

# 4. Проверка монтирования
mount | grep marker-share

# 5. Проверка синхронизированных файлов
ls -lh /var/lib/marker/templates/

# 6. Проверка логов
sudo tail -30 /var/log/marker-sync.log

# 7. Проверка ротации
ls -lh /var/log/marker-sync.log*
```

### Демонстрация отказоустойчивости

```bash
# 1. Отключите сеть
sudo ifconfig eth0 down

# 2. Запустите синхронизацию
sudo /usr/local/bin/marker-sync.sh

# 3. Проверьте лог (должен быть WARNING)
sudo tail -5 /var/log/marker-sync.log

# 4. Проверьте, что файлы не повреждены
ls -lh /var/lib/marker/templates/

# 5. Включите сеть обратно
sudo ifconfig eth0 up

# 6. Запустите снова (должно быть успешно)
sudo /usr/local/bin/marker-sync.sh
```

### Демонстрация удаления файлов

```bash
# 1. Создайте тестовый файл
sudo touch /var/lib/marker/templates/test_delete.txt

# 2. Запустите синхронизацию
sudo /usr/local/bin/marker-sync.sh

# 3. Проверьте (файл должен исчезнуть)
ls -lh /var/lib/marker/templates/
sudo tail -10 /var/log/marker-sync.log | grep -i "удален"
```

### Демонстрация ротации логов

```bash
# 1. Создайте большой лог (> 5 МБ)
sudo dd if=/dev/urandom bs=1M count=6 2>/dev/null | base64 > /var/log/marker-sync.log

# 2. Запустите ротацию
sudo logrotate -f /etc/logrotate.d/marker-sync

# 3. Проверьте результат
ls -lh /var/log/marker-sync.log*
# Должно быть: 3 несжатых + сжатые архивы
```

---

## 🐛 Troubleshooting

### Ошибка: `set: Illegal option -o pipefail`

**Причина**: Скрипт запускается через `sh` (dash), а не `bash`.

**Решение**:
```bash
# Проверьте shebang
head -1 /usr/local/bin/marker-sync.sh

# Исправьте на #!/bin/bash
sudo sed -i '1s|^#!.*|#!/bin/bash|' /usr/local/bin/marker-sync.sh

# Запускайте ПРАВИЛЬНО:
sudo /usr/local/bin/marker-sync.sh

# НЕ запускайте через sh:
# ❌ sudo sh /usr/local/bin/marker-sync.sh
```

### Ошибка: `mount error(112): Host is down`

**Причина**: Несовместимость версий SMB.

**Решение**: Попробуйте другие версии в скрипте:
```bash
sudo nano /usr/local/bin/marker-sync.sh
# Найдите строку с mount и измените vers=2.0 на vers=1.0 или vers=3.0
```

### Ошибка: `mount error(22): Invalid argument`

**Причина**: Недопустимые опции монтирования.

**Решение**: Уберите лишние опции (`timeo`, `soft`, `echo_interval`) — они не поддерживаются в CIFS.

### Ошибка: `Could not resolve name`

**Причина**: NetBIOS-имя не резолвится.

**Решение**: Используйте IP-адрес вместо имени сервера.

### Ошибка: `Permission denied` при монтировании

**Причина**: Неверный логин/пароль или проблема с credentials-файлом.

**Решение**:
```bash
# Проверьте формат credentials
sudo cat /etc/marker-sync/credentials
# Должно быть:
# username=your_user
# password=your_pass

# Проверьте права
sudo ls -l /etc/marker-sync/credentials
# Должно быть: 600

# Проверьте, нет ли лишних символов (Windows-переносы)
sudo cat -A /etc/marker-sync/credentials
```

### Служба не запускается по таймеру

**Решение**:
```bash
# Проверьте статус таймера
systemctl status marker-sync.timer

# Проверьте, активен ли таймер
systemctl list-timers marker-sync.timer

# Перезапустите таймер
sudo systemctl restart marker-sync.timer

# Проверьте логи journalctl
sudo journalctl -u marker-sync.service -n 50
```

## 📝 Формат логов

```
[2026-06-18 14:30:00] [INFO]    ========== СТАРТ ==========
[2026-06-18 14:30:00] [INFO]    Сервер доступен
[2026-06-18 14:30:01] [INFO]    ✅ Шара успешно смонтирована
[2026-06-18 14:30:02] [INFO]    НОВЫЙ файл: template1.xml
[2026-06-18 14:30:03] [INFO]    ОБНОВЛЕНИЕ: template2.xml
[2026-06-18 14:30:04] [INFO]    УДАЛЕНИЕ: old_template.xml
[2026-06-18 14:30:05] [WARNING] Сервер недоступен. Пропуск итерации.
[2026-06-18 14:30:06] [ERROR]   ❌ Не удалось смонтировать шара
```

**Уровни логирования:**
- `INFO` — успешные операции
- `WARNING` — сервер недоступен, пропуск итерации
- `ERROR` — ошибки записи, несовпадение хэшей, нехватка места

---

**Версия**: 1.0  
**Дата**: 2026-06-18  
**Совместимость**: Raspberry Pi OS / Raspbian (Jessie, Bookworm)


