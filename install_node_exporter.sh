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

# Проверка существующей установки
log "Проверка существующей установки Node Exporter..."

# Проверяем systemd сервис
if systemctl is-active --quiet node_exporter 2>/dev/null; then
    CURRENT_VERSION=$(node_exporter --version 2>/dev/null | grep -oP 'version \K[0-9.]+' | head -1)
    if [ ! -z "$CURRENT_VERSION" ]; then
        log "Node Exporter уже установлен (версия: $CURRENT_VERSION)"
        log "Текущая версия: $CURRENT_VERSION, Целевая версия: $NODE_EXPORTER_VERSION"
        
        if [ "$CURRENT_VERSION" = "$NODE_EXPORTER_VERSION" ]; then
            log "Версия совпадает, пропускаем установку"
            echo -e "${GREEN}Node Exporter v${CURRENT_VERSION} уже установлен и запущен!${NC}"
            echo "• Статус: $(systemctl is-active node_exporter)"
            echo "• URL метрик: http://localhost:9100/metrics"
            echo "• IP сервера: $(hostname -I | awk '{print $1}')"
            exit 0
        else
            log "Версии отличаются, обновляем до v${NODE_EXPORTER_VERSION}"
            log "Останавливаем текущую версию..."
            systemctl stop node_exporter
        fi
    else
        log "Node Exporter запущен, но версия неизвестна, обновляем..."
        systemctl stop node_exporter
    fi
fi

# Проверяем Docker контейнеры
if command -v docker &> /dev/null; then
    if docker ps --format "table {{.Names}}" | grep -q "node_exporter\|node-exporter"; then
        log "Обнаружен Node Exporter в Docker контейнере"
        log "Остановка Docker контейнера..."
        docker stop $(docker ps --format "table {{.Names}}" | grep -E "node_exporter|node-exporter" | head -1) 2>/dev/null || true
    fi
fi

# Проверяем процесс в системе
if pgrep -f "node_exporter" > /dev/null; then
    log "Обнаружен запущенный процесс node_exporter, останавливаем..."
    pkill -f "node_exporter" || true
    sleep 2
    
    # Проверяем, не запустился ли снова (автозапуск)
    sleep 3
    if pgrep -f "node_exporter" > /dev/null; then
        log "Процесс перезапустился автоматически, ищем источник автозапуска..."
        
        # Проверяем cron
        if crontab -l 2>/dev/null | grep -q "node_exporter"; then
            log "Найден автозапуск в crontab, отключаем..."
            crontab -l 2>/dev/null | grep -v "node_exporter" | crontab - 2>/dev/null || true
        fi
        
        # Проверяем systemd timers
        if systemctl list-timers --all | grep -q "node_exporter"; then
            log "Найден systemd timer, отключаем..."
            systemctl disable --now node_exporter.timer 2>/dev/null || true
        fi
        
        # Проверяем другие systemd сервисы
        for service in $(systemctl list-units --all --type=service | grep -i node_exporter | awk '{print $1}'); do
            if [ "$service" != "node_exporter.service" ]; then
                log "Отключаем сервис: $service"
                systemctl disable --now "$service" 2>/dev/null || true
            fi
        done
        
        # Останавливаем снова
        pkill -f "node_exporter" || true
        sleep 2
    fi
fi

# Настройка файрвола - пользователь должен открыть порт вручную
log "Внимание: Порт 9100 нужно будет открыть вручную после установки"

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

# Проверка статуса файрвола
log "Проверка статуса файрвола..."
FIREWALL_STATUS="неизвестно"
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "9100/tcp"; then
        FIREWALL_STATUS="открыт в UFW"
        log "Порт 9100 уже открыт в UFW"
    else
        FIREWALL_STATUS="закрыт в UFW"
        log "Порт 9100 закрыт в UFW"
    fi
elif command -v iptables &> /dev/null; then
    if iptables -L INPUT | grep -q "tcp dpt:9100"; then
        FIREWALL_STATUS="открыт в iptables"
        log "Порт 9100 уже открыт в iptables"
    else
        FIREWALL_STATUS="закрыт в iptables"
        log "Порт 9100 закрыт в iptables"
    fi
else
    FIREWALL_STATUS="файрвол не найден"
    log "Файрвол не найден"
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

# Финальная проверка автозапуска
log "Проверка автозапуска..."
sleep 2
if pgrep -f "node_exporter" | wc -l | grep -q "^1$"; then
    log "Только один процесс node_exporter запущен (правильно)"
else
    warn "Обнаружено несколько процессов node_exporter, проверьте автозапуск"
    pgrep -f "node_exporter" | while read pid; do
        log "PID $pid: $(ps -p $pid -o comm= 2>/dev/null || echo 'неизвестно')"
    done
fi

# Очистка временных файлов
log "Очистка временных файлов..."
rm -rf /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64*
rm -f /tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz

# Вывод информации
log "Установка завершена успешно!"

# Проверяем, была ли это обновление
if [ ! -z "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$NODE_EXPORTER_VERSION" ]; then
    log "Обновление с v${CURRENT_VERSION} до v${NODE_EXPORTER_VERSION} завершено"
fi
echo ""
echo -e "${BLUE}Информация о Node Exporter:${NC}"
echo "• Версия: ${NODE_EXPORTER_VERSION}"
echo "• Пользователь: ${NODE_EXPORTER_USER}"
echo "• Бинарный файл: ${NODE_EXPORTER_BIN}"
echo "• Порт: 9100"
echo "• URL метрик: http://localhost:9100/metrics"
echo "• Статус: $(systemctl is-active node_exporter)"
echo "• Файрвол: Порт 9100 $FIREWALL_STATUS"
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
echo -e "${YELLOW}⚠️  ВАЖНО: Порт 9100 должен быть открыт для бота!${NC}"
echo ""
echo -e "${GREEN}Node Exporter готов к работе!${NC}"
