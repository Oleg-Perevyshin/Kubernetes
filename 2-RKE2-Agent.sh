#!/bin/bash

# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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
echo -e "${GREEN}ЭТАП 2: Настройка агентов${NC}"
echo -e "${GREEN}[1/3] Проверка доступность агентов кластера${NC}"
for node in "${ALL_AGENTS[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}  Агент $node недоступен, установка прервана${NC}"
    exit 1
  }
done
echo -e "${GREEN}  ✓ Все агенты доступны${NC}"
#
#
echo -e "${GREEN}[2/3] Читаем токен доступа к серверу${NC}"
TOKEN=$(<"$HOME/.kube/${PREFIX_CONFIG}_token") || {
  echo -e "${RED}  Ошибка при чтении токена из $HOME/.kube/${PREFIX_CONFIG}_token, установка прервана${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Токен доступа успешно получен${NC}"
#
#
echo -e "${GREEN}[3/3] Настраиваем агенты${NC}"
for agent in "${ALL_AGENTS[@]}"; do
  echo -e "${GREEN}  Подключаемся к агенту $agent${NC}"
  # shellcheck disable=SC2087
  ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$agent" sudo bash -c "bash -s" <<EOF
    # Прекращение выполнения при любой ошибке
    set -euo pipefail
    #
    #
    timedatectl set-ntp off; timedatectl set-ntp on; echo -e "${GREEN}  Синхронизация времени выполнена${NC}"
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - || {
      echo -e "${RED}  Ошибка при установке RKE2 агента, установка прервана${NC}"
      exit 1
    }
    echo -e "${GREEN}  ✓ RKE2 установлен${NC}"
    #
    #
    echo -e "${GREEN}  Указываем параметры для подключения к кластеру${NC}"
    mkdir -p /etc/rancher/rke2
    rm -f /etc/rancher/rke2/config.yaml
    cat <<EOL | sudo tee "/etc/rancher/rke2/config.yaml" > /dev/null
server: https://${NODES[server]}:9345
token: $TOKEN
EOL
    echo -e "${GREEN}  ✓ Параметры заданы${NC}"
    #
    #
    echo -e "${GREEN}  Запускаем сервис rke2-agent${NC}"
    systemctl enable --now rke2-agent.service
    systemctl start rke2-agent.service
    sleep 5;
    if ! systemctl is-active --quiet rke2-agent.service; then
      echo -e "${RED}  Сервис rke2-agent не запустился, установка прервана${NC}"
      exit 1
    fi
    echo -e "${GREEN}  ✓ Агент $agent присоединился к кластеру${NC}"
EOF
done

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Кластер RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
