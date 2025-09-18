#!/bin/bash

# Скрипт установки Node Exporter для мониторинга
# Node Exporter Installation Script for Monitoring

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    error "Этот скрипт должен быть запущен с правами root"
    exit 1
fi

# Версия Node Exporter
NODE_EXPORTER_VERSION="1.9.1"
NODE_EXPORTER_USER="node_exporter"
NODE_EXPORTER_GROUP="node_exporter"
NODE_EXPORTER_HOME="/opt/node_exporter"
NODE_EXPORTER_BIN="/usr/local/bin/node_exporter"

log "Начинаем установку Node Exporter v${NODE_EXPORTER_VERSION}"

# Обновление системы
log "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
log "Установка необходимых пакетов..."
apt install -y wget curl unzip

# Создание пользователя для Node Exporter
log "Создание пользователя ${NODE_EXPORTER_USER}..."
if ! id "$NODE_EXPORTER_USER" &>/dev/null; then
    useradd --no-create-home --shell /bin/false "$NODE_EXPORTER_USER"
    log "Пользователь ${NODE_EXPORTER_USER} создан"
else
    log "Пользователь ${NODE_EXPORTER_USER} уже существует"
fi

# Скачивание Node Exporter
log "Скачивание Node Exporter..."
cd /tmp
if [ -f "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" ]; then
    log "Файл уже скачан"
else
    wget "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"
    log "Node Exporter скачан"
fi

# Распаковка архива
log "Распаковка архива..."
tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

# Установка бинарного файла
log "Установка бинарного файла..."
cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" "$NODE_EXPORTER_BIN"
chown "$NODE_EXPORTER_USER:$NODE_EXPORTER_GROUP" "$NODE_EXPORTER_BIN"
chmod +x "$NODE_EXPORTER_BIN"

# Создание systemd сервиса
log "Создание systemd сервиса..."
cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=$NODE_EXPORTER_USER
Group=$NODE_EXPORTER_GROUP
Type=simple
ExecStart=$NODE_EXPORTER_BIN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка systemd
log "Перезагрузка systemd..."
systemctl daemon-reload

# Включение автозапуска
log "Включение автозапуска..."
systemctl enable node_exporter

# Запуск сервиса
log "Запуск Node Exporter..."
systemctl start node_exporter

# Проверка статуса
sleep 3
if systemctl is-active --quiet node_exporter; then
    log "Node Exporter успешно запущен"
else
    error "Ошибка запуска Node Exporter"
    systemctl status node_exporter
    exit 1
fi

# Настройка файрвола
log "Настройка файрвола..."
if command -v ufw &> /dev/null; then
    ufw allow 9100/tcp
    log "Порт 9100 открыт в UFW"
elif command -v iptables &> /dev/null; then
    iptables -A INPUT -p tcp --dport 9100 -j ACCEPT
    log "Порт 9100 открыт в iptables"
else
    warn "Файрвол не найден, откройте порт 9100 вручную"
fi

# Проверка работы
log "Проверка работы Node Exporter..."
sleep 5
if curl -s http://localhost:9100/metrics | grep -q "node_cpu_seconds_total"; then
    log "Node Exporter работает корректно"
else
    error "Node Exporter не отвечает на запросы"
    exit 1
fi

# Очистка временных файлов
log "Очистка временных файлов..."
rm -rf /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
rm -f /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

# Вывод информации
log "Установка завершена успешно!"
echo ""
echo -e "${BLUE}Информация о Node Exporter:${NC}"
echo "• Версия: ${NODE_EXPORTER_VERSION}"
echo "• Пользователь: ${NODE_EXPORTER_USER}"
echo "• Бинарный файл: ${NODE_EXPORTER_BIN}"
echo "• Порт: 9100"
echo "• URL метрик: http://localhost:9100/metrics"
echo "• Статус: $(systemctl is-active node_exporter)"
echo ""
echo -e "${BLUE}Полезные команды:${NC}"
echo "• Проверить статус: systemctl status node_exporter"
echo "• Перезапустить: systemctl restart node_exporter"
echo "• Остановить: systemctl stop node_exporter"
echo "• Посмотреть логи: journalctl -u node_exporter -f"
echo "• Проверить метрики: curl http://localhost:9100/metrics"
echo ""
echo -e "${GREEN}Node Exporter готов к работе!${NC}"
