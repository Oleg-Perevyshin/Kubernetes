#!/bin/bash
# Вызвываем chmod +x 4-Longhorn.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

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

####################################################################################################
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 4: Установка Longhorn${NC}"
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -e;
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  #
  #
  echo -e "${GREEN}  Проверяем установку kubectl и Helm${NC}";
  if ! command -v kubectl &> /dev/null; then echo -e "${RED}kubectl не установлен, установка прервана${NC}"; exit 1; fi
  if ! command -v helm &> /dev/null; then echo -e "${RED}helm не установлен, установка прервана${NC}"; exit 1; fi
  #
  #
  echo -e "${GREEN}  Добавляем репозитории Longhorn${NC}";
  helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при добавлении репозитория Longhorn, установка прервана${NC}"; exit 1;
  }
  helm repo update >/dev/null 2>&1;
  #
  #
  echo -e "${GREEN}  Устанавливаем Longhorn${NC}";
  helm upgrade -i longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --wait --timeout 180m >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при установке Longhorn, установка прервана${NC}"; exit 1;
  }
EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Longhorn установлен${NC}"
echo -e "${GREEN}${NC}"
