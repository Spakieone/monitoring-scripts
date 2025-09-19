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
            log "Версия совпадает, пропускаем установку Node Exporter"
            log "Продолжаем установку агента мониторинга..."
            SKIP_NODE_EXPORTER_INSTALL=true
        else
            log "Версии отличаются, обновляем до v${NODE_EXPORTER_VERSION}"
            log "Останавливаем текущую версию..."
            systemctl stop node_exporter
            SKIP_NODE_EXPORTER_INSTALL=false
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

# Проверяем, что Node Exporter запущен
if ! systemctl is-active --quiet node_exporter; then
    log "Запуск Node Exporter..."
    systemctl start node_exporter
    sleep 3
    if systemctl is-active --quiet node_exporter; then
        log "Node Exporter успешно запущен"
    else
        error "Ошибка запуска Node Exporter"
        systemctl status node_exporter
        exit 1
    fi
else
    log "Node Exporter уже запущен"
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

# Установка Node Exporter (если нужно)
if [ "$SKIP_NODE_EXPORTER_INSTALL" != "true" ]; then
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
else
    log "Пропуск установки Node Exporter (версия совпадает)"
fi

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

# Установка агента мониторинга
log "Установка агента мониторинга..."
MONITORING_AGENT_DIR="/opt/monitoring_agent"

# Создаем директорию для агента
mkdir -p "$MONITORING_AGENT_DIR"

# Запрос настроек агента мониторинга
echo ""
echo -e "${BLUE}Настройка агента мониторинга:${NC}"
echo "Введите URL вашего бота (например: http://93.188.206.70:8080)"
read -p "URL бота: " BOT_URL

# Проверяем URL
if [ -z "$BOT_URL" ]; then
    BOT_URL="http://your-bot-server.com"
    warn "URL бота не указан, используется по умолчанию: $BOT_URL"
fi

# Автоматически определяем имя сервера
AUTO_SERVER_NAME=$(hostname)
echo "Введите имя сервера (по умолчанию: $AUTO_SERVER_NAME)"
read -p "Имя сервера: " SERVER_NAME

# Проверяем имя сервера
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME="$AUTO_SERVER_NAME"
    log "Используется автоматически определенное имя: $SERVER_NAME"
fi

log "Настройки агента:"
log "• URL бота: $BOT_URL"
log "• Имя сервера: $SERVER_NAME"

# Создаем агент мониторинга
log "Создание агента мониторинга..."
cat > "$MONITORING_AGENT_DIR/monitoring_agent.py" << EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
Агент мониторинга для VPN серверов
Собирает метрики с Node Exporter и RemnaNode
"""

import asyncio
import aiohttp
import json
import os
import subprocess
import time
from datetime import datetime
from typing import Dict, Any, Optional

class MonitoringAgent:
    def __init__(self, bot_url: str, server_name: str):
        self.bot_url = bot_url
        self.server_name = server_name
        self.node_exporter_url = "http://localhost:9100"
        self.remnanode_log_path = "/var/log/remnanode"
        self.session = None
        
    async def start(self):
        """Запуск агента мониторинга"""
        self.session = aiohttp.ClientSession()
        print(f"[{datetime.now()}] Агент мониторинга запущен для {self.server_name}")
        
        while True:
            try:
                await self.collect_and_send_metrics()
                await asyncio.sleep(30)  # Отправляем каждые 30 секунд
            except Exception as e:
                print(f"[{datetime.now()}] Ошибка: {e}")
                await asyncio.sleep(10)
    
    async def collect_and_send_metrics(self):
        """Сбор и отправка метрик"""
        metrics = {
            "server_name": self.server_name,
            "timestamp": datetime.now().isoformat(),
            "node_exporter": await self.get_node_exporter_metrics(),
            "remnanode": await self.get_remnanode_metrics(),
            "system": await self.get_system_metrics()
        }
        
        await self.send_metrics(metrics)
    
    async def get_node_exporter_metrics(self) -> Dict[str, Any]:
        """Получение метрик от Node Exporter"""
        try:
            async with self.session.get(f"{self.node_exporter_url}/metrics") as response:
                if response.status == 200:
                    text = await response.text()
                    return self.parse_prometheus_metrics(text)
        except Exception as e:
            print(f"Ошибка получения метрик Node Exporter: {e}")
        
        return {"status": "error", "message": "Node Exporter недоступен"}
    
    def parse_prometheus_metrics(self, text: str) -> Dict[str, Any]:
        """Парсинг метрик Prometheus"""
        metrics = {}
        lines = text.split('\n')
        
        for line in lines:
            if line.startswith('#') or not line.strip():
                continue
                
            if ' ' in line:
                name, value = line.rsplit(' ', 1)
                try:
                    metrics[name] = float(value)
                except ValueError:
                    metrics[name] = value
        
        # Извлекаем ключевые метрики
        return {
            "cpu_usage": metrics.get("node_cpu_seconds_total", 0),
            "memory_total": metrics.get("node_memory_MemTotal_bytes", 0),
            "memory_available": metrics.get("node_memory_MemAvailable_bytes", 0),
            "disk_total": metrics.get("node_filesystem_size_bytes", 0),
            "disk_free": metrics.get("node_filesystem_free_bytes", 0),
            "network_rx": metrics.get("node_network_receive_bytes_total", 0),
            "network_tx": metrics.get("node_network_transmit_bytes_total", 0),
            "load_1m": metrics.get("node_load1", 0),
            "load_5m": metrics.get("node_load5", 0),
            "load_15m": metrics.get("node_load15", 0),
            "status": "ok"
        }
    
    async def get_remnanode_metrics(self) -> Dict[str, Any]:
        """Получение метрик RemnaNode"""
        try:
            # Проверяем статус Docker контейнера
            result = subprocess.run(
                ["docker", "inspect", "remnanode", "--format", "{{.State.Status}}"],
                capture_output=True, text=True, timeout=5
            )
            
            container_status = result.stdout.strip() if result.returncode == 0 else "unknown"
            
            # Получаем использование ресурсов
            result = subprocess.run(
                ["docker", "stats", "remnanode", "--no-stream", "--format", 
                 "{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}}"],
                capture_output=True, text=True, timeout=5
            )
            
            stats = result.stdout.strip().split(',') if result.returncode == 0 else []
            
            # Анализируем логи
            log_metrics = await self.analyze_remnanode_logs()
            
            return {
                "status": container_status,
                "cpu_percent": stats[0] if len(stats) > 0 else "0%",
                "memory_usage": stats[1] if len(stats) > 1 else "0B / 0B",
                "network_io": stats[2] if len(stats) > 2 else "0B / 0B",
                "block_io": stats[3] if len(stats) > 3 else "0B / 0B",
                "log_metrics": log_metrics
            }
            
        except Exception as e:
            print(f"Ошибка получения метрик RemnaNode: {e}")
            return {"status": "error", "message": str(e)}
    
    async def analyze_remnanode_logs(self) -> Dict[str, Any]:
        """Анализ логов RemnaNode"""
        try:
            # Читаем последние 100 строк лога
            result = subprocess.run(
                ["tail", "-100", f"{self.remnanode_log_path}/access.log"],
                capture_output=True, text=True, timeout=5
            )
            
            if result.returncode == 0:
                lines = result.stdout.split('\n')
                return {
                    "total_lines": len(lines),
                    "recent_connections": len([l for l in lines if 'connect' in l.lower()]),
                    "recent_errors": len([l for l in lines if 'error' in l.lower()]),
                    "last_activity": lines[-1] if lines else "no_activity"
                }
        except Exception as e:
            print(f"Ошибка анализа логов: {e}")
        
        return {"status": "error", "message": "Логи недоступны"}
    
    async def get_system_metrics(self) -> Dict[str, Any]:
        """Получение системных метрик"""
        try:
            # Uptime
            with open('/proc/uptime', 'r') as f:
                uptime_seconds = float(f.read().split()[0])
            
            # Количество процессов
            result = subprocess.run(["ps", "aux"], capture_output=True, text=True)
            process_count = len(result.stdout.split('\n')) - 1
            
            return {
                "uptime_seconds": uptime_seconds,
                "process_count": process_count,
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            return {"status": "error", "message": str(e)}
    
    async def send_metrics(self, metrics: Dict[str, Any]):
        """Отправка метрик в бот"""
        try:
            async with self.session.post(
                f"{self.bot_url}/api/monitoring/metrics",
                json=metrics,
                timeout=10
            ) as response:
                if response.status == 200:
                    print(f"[{datetime.now()}] Метрики отправлены успешно")
                else:
                    print(f"[{datetime.now()}] Ошибка отправки: {response.status}")
        except Exception as e:
            print(f"[{datetime.now()}] Ошибка отправки метрик: {e}")
    
    async def stop(self):
        """Остановка агента"""
        if self.session:
            await self.session.close()

async def main():
    """Главная функция"""
    # Настройки
    BOT_URL = "$BOT_URL"
    SERVER_NAME = "$SERVER_NAME"
    
    agent = MonitoringAgent(BOT_URL, SERVER_NAME)
    
    try:
        await agent.start()
    except KeyboardInterrupt:
        print("Остановка агента...")
        await agent.stop()

if __name__ == "__main__":
    asyncio.run(main())
EOF

chmod +x "$MONITORING_AGENT_DIR/monitoring_agent.py"
log "Агент мониторинга создан"

# Устанавливаем зависимости Python
log "Установка зависимостей Python..."
apt install -y python3-pip python3-aiohttp
pip3 install aiohttp

# Создаем systemd сервис для агента
log "Создание systemd сервиса для агента..."
cat > /etc/systemd/system/monitoring-agent.service << 'EOF'
[Unit]
Description=Monitoring Agent for VPN Server
After=network.target node_exporter.service
Wants=node_exporter.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/monitoring_agent
ExecStart=/usr/bin/python3 /opt/monitoring_agent/monitoring_agent.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Переменные окружения
Environment=PYTHONUNBUFFERED=1
Environment=MONITORING_BOT_URL=http://your-bot-server.com
Environment=SERVER_NAME=NotouchKZ2

[Install]
WantedBy=multi-user.target
EOF

# Перезагружаем systemd
systemctl daemon-reload

# Включаем автозапуск агента
systemctl enable monitoring-agent

# Запускаем агент
log "Запуск агента мониторинга..."
systemctl start monitoring-agent

# Проверяем статус агента
sleep 3
if systemctl is-active --quiet monitoring-agent; then
    log "Агент мониторинга успешно запущен"
else
    warn "Ошибка запуска агента мониторинга"
    systemctl status monitoring-agent
fi

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
echo -e "${BLUE}Информация об агенте мониторинга:${NC}"
echo "• Статус: $(systemctl is-active monitoring-agent)"
echo "• Директория: $MONITORING_AGENT_DIR"
echo "• Логи: journalctl -u monitoring-agent -f"
echo ""
echo -e "${BLUE}Полезные команды:${NC}"
echo "• Node Exporter статус: systemctl status node_exporter"
echo "• Агент мониторинга статус: systemctl status monitoring-agent"
echo "• Перезапустить агент: systemctl restart monitoring-agent"
echo "• Логи агента: journalctl -u monitoring-agent -f"
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
