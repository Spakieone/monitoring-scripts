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
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

log "Начинаем установку Node Exporter v${NODE_EXPORTER_VERSION}"

# Запрос IP для открытия порта
echo ""
echo -e "${BLUE}Настройка файрвола:${NC}"
echo "Для работы мониторинга нужно открыть порт 9100"
echo "Выберите вариант:"
echo "1) Открыть порт для всех IP (0.0.0.0/0)"
echo "2) Открыть порт для конкретного IP"
echo "3) Не открывать порт (открыть вручную позже)"
echo ""
read -p "Введите номер варианта (1-3): " firewall_choice

case $firewall_choice in
    1)
        FIREWALL_IP="0.0.0.0/0"
        log "Порт 9100 будет открыт для всех IP"
        ;;
    2)
        read -p "Введите IP адрес для открытия порта 9100: " FIREWALL_IP
        if [[ $FIREWALL_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log "Порт 9100 будет открыт для IP: $FIREWALL_IP"
        else
            error "Неверный формат IP адреса. Используется 0.0.0.0/0"
            FIREWALL_IP="0.0.0.0/0"
        fi
        ;;
    3)
        FIREWALL_IP="skip"
        log "Порт 9100 не будет открыт автоматически"
        ;;
    *)
        error "Неверный выбор. Используется вариант 1 (все IP)"
        FIREWALL_IP="0.0.0.0/0"
        ;;
esac

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
log "URL: ${NODE_EXPORTER_URL}"
cd /tmp
if [ -f "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" ]; then
    log "Файл уже скачан"
else
    wget "${NODE_EXPORTER_URL}"
    if [ $? -eq 0 ]; then
        log "Node Exporter v${NODE_EXPORTER_VERSION} успешно скачан"
    else
        error "Ошибка скачивания Node Exporter"
        exit 1
    fi
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
if [ "$FIREWALL_IP" != "skip" ]; then
    log "Настройка файрвола..."
    if command -v ufw &> /dev/null; then
        if [ "$FIREWALL_IP" = "0.0.0.0/0" ]; then
            ufw allow 9100/tcp
            log "Порт 9100 открыт в UFW для всех IP"
        else
            ufw allow from $FIREWALL_IP to any port 9100
            log "Порт 9100 открыт в UFW для IP: $FIREWALL_IP"
        fi
    elif command -v iptables &> /dev/null; then
        if [ "$FIREWALL_IP" = "0.0.0.0/0" ]; then
            iptables -A INPUT -p tcp --dport 9100 -j ACCEPT
            log "Порт 9100 открыт в iptables для всех IP"
        else
            iptables -A INPUT -p tcp -s $FIREWALL_IP --dport 9100 -j ACCEPT
            log "Порт 9100 открыт в iptables для IP: $FIREWALL_IP"
        fi
    else
        warn "Файрвол не найден, откройте порт 9100 вручную"
    fi
else
    log "Пропуск настройки файрвола (выбран вариант 3)"
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
if [ "$FIREWALL_IP" != "skip" ]; then
    echo "• Файрвол: Порт 9100 открыт для $FIREWALL_IP"
else
    echo "• Файрвол: Порт 9100 НЕ открыт (откройте вручную)"
fi
echo ""
echo -e "${BLUE}Полезные команды:${NC}"
echo "• Проверить статус: systemctl status node_exporter"
echo "• Перезапустить: systemctl restart node_exporter"
echo "• Остановить: systemctl stop node_exporter"
echo "• Посмотреть логи: journalctl -u node_exporter -f"
echo "• Проверить метрики: curl http://localhost:9100/metrics"
echo ""
echo -e "${BLUE}Для мониторинга в боте используйте:${NC}"
echo "• IP сервера: $(hostname -I | awk '{print $1}')"
echo "• Порт: 9100"
echo "• URL: http://$(hostname -I | awk '{print $1}'):9100/metrics"
echo ""
echo -e "${GREEN}Node Exporter готов к работе!${NC}"
