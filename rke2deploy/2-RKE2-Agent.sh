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
PREFIX_CONFIG="home"

# Машины кластера
if [[ "$PREFIX_CONFIG" == "home" ]]; then
  declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
elif [[ "$PREFIX_CONFIG" == "office" ]]; then
  declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
else
  echo -e "${RED}Неизвестный кластер $PREFIX_CONFIG, установка прервана${NC}"
  exit 1
fi
ALL_AGENTS=("${NODES[agent_1]}" "${NODES[agent_2]}")

####################################################################################################
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 2: Настройка агентов${NC}"
token=$(<"$HOME/.kube/${PREFIX_CONFIG}_token") || {
  echo -e "${RED}  Ошибка при чтении токена из $HOME/.kube/${PREFIX_CONFIG}_token, установка прервана${NC}"
  exit 1
}

for newnode in "${ALL_AGENTS[@]}"; do
  # shellcheck disable=SC2087
  ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$newnode" sudo bash -c "bash -s" <<EOF
    set -e;
    #
    #
    echo -e "${GREEN}  Настраиваем узле $newnode${NC}";
    timedatectl set-ntp off; timedatectl set-ntp on; echo -e "${GREEN}    Синхронизация времени выполнена${NC}";
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - || { echo -e "${RED}  Ошибка при установке RKE2 агента, установка прервана${NC}"; exit 1; }
    echo -e "${GREEN}  RKE2 установлен${NC}";
    #
    #
    echo -e "${GREEN}    Настраиваем параметры для подключения к кластеру${NC}";
    mkdir -p /etc/rancher/rke2;
    rm -f /etc/rancher/rke2/config.yaml;
    cat <<EOL | sudo tee "/etc/rancher/rke2/config.yaml" > /dev/null
server: https://${NODES[server]}:9345
token: $token
EOL
    #
    #
    echo -e "${GREEN}    Запускаем сервис rke2-agent${NC}";
    systemctl enable --now rke2-agent.service;
    systemctl start rke2-agent.service;
    sleep 5;
    if ! systemctl is-active --quiet rke2-agent.service; then echo -e "${RED}  Сервис rke2-agent не запустился, установка прервана${NC}"; exit 1; fi
    echo -e "${GREEN}  Агент $newnode присоединился к кластеру${NC}"; echo -e "${GREEN}${NC}";
EOF
done
echo -e "${GREEN}  Конфигурация для подключения $HOME/.kube/${PREFIX_CONFIG}_config${NC}"
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Кластер RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
