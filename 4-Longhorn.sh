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

####################################################################################################
echo -e "${GREEN}ЭТАП 4: Установка Longhorn${NC}"
echo -e "${GREEN}[1/4] Проверяем доступность сервера${NC}"
ping -c 1 -W 1 "${NODES[server]}" >/dev/null || {
  echo -e "${RED}  Сервер ${NODES[server]} недоступен${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Сервер ${NODES[server]} доступен${NC}"
#
#
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  # Прекращение выполнения при любой ошибке
  set -euo pipefail
  #
  #
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  #
  #
  echo -e "${GREEN}[2/4] Проверяем установку kubectl и Helm${NC}"
  if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}  kubectl не установлен, установка прервана${NC}"
    exit 1
  fi
  if ! command -v helm &> /dev/null; then
    echo -e "${RED}  helm не установлен, установка прервана${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ kubectl и Helm установлены${NC}"
  #
  #
  echo -e "${GREEN}[3/4] Добавляем репозитории Longhorn${NC}"
  helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при добавлении репозитория Longhorn, установка прервана${NC}"
    exit 1
  }
  helm repo update >/dev/null 2>&1
  echo -e "${GREEN}  ✓ Репозитории Longhorn добавлен${NC}"
  #
  #
  echo -e "${GREEN}[4/4] Устанавливаем Longhorn${NC}";
  helm upgrade -i longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set csi.enabled=true \
  --set defaultSettings.backupTarget="" \
  --wait --timeout 180m || {
    echo -e "${RED}  Ошибка при установке Longhorn, установка прервана${NC}"
    exit 1
  }
EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Longhorn установлен${NC}"
echo -e "${GREEN}${NC}"
