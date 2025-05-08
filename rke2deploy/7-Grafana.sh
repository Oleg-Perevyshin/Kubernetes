#!/bin/bash
# Вызвываем chmod +x 7-Grafana.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"
PREFIX_CONFIG="office"
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
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -e;
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

  echo -e "${GREEN}  Проверяем установку kubectl и Helm${NC}";
  if ! command -v kubectl &> /dev/null; then echo -e "${RED}kubectl не установлен, установка прервана${NC}"; exit 1; fi
  if ! command -v helm &> /dev/null; then echo -e "${RED}helm не установлен, установка прервана${NC}"; exit 1; fi

  echo -e "${GREEN}  Добавляем репозиторий Prometheus${NC}";
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update || {
    echo -e "${RED}  Ошибка добавления репозитория Prometheus${NC}"; exit 1;
  }
  helm repo update
  #
  #
  echo -e "${GREEN}  Добавляем пространство имен для мониторинга${NC}";
  if ! kubectl get namespace monitoring >/dev/null 2>&1; then
    kubectl create namespace monitoring >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка создания пространства имен${NC}"
      exit 1
    }
  fi
  #
  #

  #
  #
  echo -e "${GREEN}  Проверяем установку${NC}";
  kubectl get ingress -n monitoring || {
    echo -e "${RED}  Ошибка проверки Ingress${NC}"; exit 1;
  }

  echo -e "${YELLOW}  Логин: admin | Пароль: ${GRAFANA_PASSWORD}${NC}"
EOF

echo -e "${GREEN}Grafana установлен и доступен по адресу: https://${GRAFANA_HOST}${NC}"
