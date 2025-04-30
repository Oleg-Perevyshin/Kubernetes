#!/bin/bash
# Вызвываем chmod +x rke2deploy/2-RKE2-Agent.sh; из командной строки чтоб сделать файл исполняемым
set -e # Прекращение выполнения при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"

# Машины кластера
declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
# declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
ALL_AGENTS=("${NODES[agent_1]}" "${NODES[agent_2]}")

####################################################################################################
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 2: Настройка агентов${NC}"
token=$(<"$HOME/.kube/token") || {
  echo -e "${RED}  Ошибка при чтении токена из $HOME/.kube/token, установка прервана${NC}"
  exit 1
}

for newnode in "${ALL_AGENTS[@]}"; do
  # shellcheck disable=SC2087
  ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$newnode" sudo bash -c "bash -s" <<EOF
    set -e;

    timedatectl set-ntp off; timedatectl set-ntp on; echo -e "${GREEN}  Синхронизация времени на узле $newnode выполнена${NC}";
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - || { echo -e "${RED}  Ошибка при установке RKE2 агента, установка прервана${NC}"; exit 1; }
    echo -e "${GREEN}  RKE2 установлен${NC}";

    # Записываем токен и адрес сервера в конфигурацию
    mkdir -p /etc/rancher/rke2;
    rm -f /etc/rancher/rke2/config.yaml;
    cat <<EOL | sudo tee "/etc/rancher/rke2/config.yaml" > /dev/null
server: https://${NODES[server]}:9345
token: $token
EOL
    #
    #
    echo -e "${GREEN}  Запускаем сервис rke2-agent${NC}";
    systemctl enable --now rke2-agent.service;
    sleep 5;
    if ! systemctl is-active --quiet rke2-agent.service; then echo -e "${RED}  Сервис rke2-agent не запустился, установка прервана${NC}"; exit 1; fi
    echo -e "${GREEN}  Агент $newnode присоединился к кластеру${NC}"; echo -e "${GREEN}${NC}";
EOF
done

echo -e "${GREEN}Конфигурация для подключения $HOME/.kube/config${NC}"
echo -e "${GREEN}Кластер RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
