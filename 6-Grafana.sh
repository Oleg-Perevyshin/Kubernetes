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
GRAFANA_HOST="grafana.${PREFIX_CONFIG}.local"
GRAFANA_PASSWORD="MCMega2005!"

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
echo -e "${GREEN}ЭТАП 7: Установка мониторинга${NC}"
echo -e "${GREEN}[1/] Проверяем доступность сервера${NC}"
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
  echo -e "${GREEN}[2/] Проверяем установку kubectl и Helm${NC}"
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
  echo -e "${GREEN}[3/] Добавляем репозиторий Prometheus${NC}";
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория Prometheus${NC}"; exit 1;
  }
  echo -e "${GREEN}  ✓ Репозитории добавлен${NC}"
  #
  #
  echo -e "${GREEN}[4/] Добавляем пространство имен${NC}";
  if ! kubectl get namespace monitoring >/dev/null 2>&1; then
    kubectl create namespace monitoring >/dev/null || {
      echo -e "${RED}  Ошибка создания пространства имен${NC}"
      exit 1
    }
  fi
  echo -e "${GREEN}  ✓ Пространство имен установлено${NC}"
  #
  #

  #
  #
  # echo -e "${GREEN}[9/9] Проверяем создание Ingress${NC}"
  # kubectl get ingress -n monitoring  >/dev/null || {
  #   echo -e "${RED}  Ошибка проверки Ingress${NC}"; exit 1;
  # }
  # echo -e "${GREEN}  ✓ Ingress успешно проверен${NC}"

  echo -e "${YELLOW}  Логин: admin | Пароль: ${GRAFANA_PASSWORD}${NC}"
EOF

echo -e "${GREEN}Grafana установлен и доступен по адресу: https://${GRAFANA_HOST}${NC}"
