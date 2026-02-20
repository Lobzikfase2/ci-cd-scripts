#!/bin/bash

set -euo pipefail

# Логирование
log() {
    local text="$1"
    local char="${2:-=}"
    local width=70

    # Проверяем, что текст пустой или состоит только из пробелов
    if [[ -z "${text// }" ]]; then
        printf '%*s' $width '' | tr ' ' "$char"
        echo
    else
        text=$(echo "$text" | tr '[:lower:]' '[:upper:]')
        local text_part=" $text "
        local text_len=${#text_part}
        local symbols=$((width - text_len))
        local left=$((symbols / 2))
        local right=$((symbols - left))

        printf '%*s' $left '' | tr ' ' "$char"
        echo -n "$text_part"
        printf '%*s' $right '' | tr ' ' "$char"
        echo
    fi
}

# Функция для получения информации о пользователе, который запустил скрипт
set_user_info() {
    if [ -n "$SUDO_USER" ]; then
        # Запущено через sudo
        USER_NAME="$SUDO_USER"
        USER_HOME=$(eval echo ~$SUDO_USER)
    else
        # Запущено напрямую
        USER_NAME="$USER"
        USER_HOME="$HOME"
    fi
    export USER_NAME USER_HOME
}

# Получение порта SSH
get_ssh_port() {
    echo $(awk '/^Port / {print $2}' /etc/ssh/sshd_config 2>/dev/null || echo "22")
}


# ------------------------------------------------------------------------------------------


# Настраиваем ufw
configure_ufw() {
    log "Настройка UFW (порты ssh, 80, 443 - TCP)"
    ssh_port=$(get_ssh_port)
    sudo ufw --force disable
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow $ssh_port/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
    sudo ufw status verbose
}

# Удаляем, заменяя на бэкап, базовые настройки ядра
backup_sysctl() {
    log "Бэкап ядра (sysctl)"
    if [ -f /etc/sysctl.conf ]; then
      sudo mv /etc/sysctl.conf /etc/sysctl.conf.bak
      echo "✅ /etc/sysctl.conf переименован в .bak"
    else
        echo "ℹ️ /etc/sysctl.conf не найден, пропускаю создание бэкапа"
    fi
}

# Настраиваем ядро под работу с прокси/vpn
configure_sysctl() {
  log "Конфигурация ядра (sysctl)"
  sudo tee /etc/sysctl.d/99-tuning.conf > /dev/null <<EOF
# Производительность/TLS стандарт
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_syncookies = 1

# Производительность
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384

# Хуже не будет (пригодится для VLESS)
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# Хуже не будет (но полезен только для UDP)
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_rfc1337 = 0
EOF
    sudo sysctl --system || true
}


# ------------------------------------------------------------------------------------------


# Функция для очистки предыдущих установок Docker
cleanup_docker() {
    log "Очистка предыдущих установок Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose 2>/dev/null || true
    sudo rm -rf /var/lib/docker
    sudo rm -rf /var/lib/containerd
    sudo rm -rf /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list
    sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    sudo rm -f /usr/local/bin/docker-compose
    sudo rm -f /etc/bash_completion.d/docker-compose
    sudo groupdel docker 2>/dev/null || true
}


# Установка Docker (для Ubuntu 20.04)
install_docker() {
    log "Установка Docker"
    (
        umask 0022

        # sudo apt-get update
        sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg

        # Добавляем официальный GPG ключ Docker
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        # Добавляем репозиторий Docker
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Запускаем и включаем демон Docker
        sudo systemctl enable docker
        sudo systemctl start docker
    )
}

# Проверка Docker (через sudo)
check_docker() {
    log "Проверка работы Docker"
    if ! sudo docker run --rm hello-world; then
        echo "Ошибка при запуске hello-world"
        exit 1
    fi
}

# Обеспечивает наличие работающего Docker: проверка, установка с очисткой при ошибке, добавление пользователя в группу
ensure_docker() {
    log "Проверка наличия Docker"

    # Функция для попытки установки с возможной очисткой
    attempt_install() {
        if ! install_docker; then
            log "Первая установка не удалась, выполняю полную очистку и повторную установку"
            cleanup_docker
            install_docker
        fi
    }

    # Проверяем, установлен ли Docker (команда docker существует)
    if command -v docker &> /dev/null; then
        echo "Docker уже установлен. Проверяю работоспособность..."
        if sudo docker run --rm hello-world &> /dev/null; then
            echo "Docker работает корректно."
        else
            echo "Docker установлен, но не работает. Попытка переустановки..."
            attempt_install
        fi
    else
        echo "Docker не найден. Устанавливаю..."
        attempt_install
    fi

    # Финальная проверка работоспособности
    if ! sudo docker run --rm hello-world &> /dev/null; then
        echo "Ошибка: Docker не работает после установки."
        exit 1
    fi

    # Добавляем пользователя в группу docker для использования без sudo
    if ! groups "$USER_NAME" | grep -q docker; then
        log "Добавление пользователя $USER_NAME в группу docker"
        sudo usermod -aG docker "$USER_NAME"
        echo "Пользователь $USER_NAME добавлен в группу docker."
        echo "Чтобы использовать Docker без sudo, выйдите из системы и зайдите заново,"
        echo "либо выполните 'newgrp docker' в текущей сессии."
    else
        echo "Пользователь $USER_NAME уже в группе docker."
    fi

    log "Docker готов к работе."
}
