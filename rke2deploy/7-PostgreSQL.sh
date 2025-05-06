#!/bin/bash
# Вызвываем chmod +x 7-PostgreSQL.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"
PREFIX_CONFIG="office"

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
echo -e "${GREEN}ЭТАП 5: Установка CloudNative-PG${NC}"
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
  echo -e "${GREEN}  Применением CloudNative-PG cnpg-1.25.1.yaml${NC}";
  kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка применения CloudNative-PG cnpg-1.25.1.yaml${NC}"
    exit 1
  }
  #
  #
  echo -e "${GREEN}    Настраиваем PostgreSQL${NC}";
  mkdir -p /etc/rancher/rke2;
  rm -f /etc/rancher/rke2/config.yaml;
  cat <<EOL | sudo tee "/etc/rancher/rke2/postgresql.yaml" > /dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cluster-with-metrics

spec:
  instances: 1

  storage:
    size: 1Gi

  monitoring:
    enablePodMonitor: true
EOL
  #
  #
  echo -e "${GREEN}  Добавляем репозитории Prometheus${NC}";
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при добавлении репозитория Prometheus, установка прервана${NC}"; exit 1;
  }
  helm repo update >/dev/null 2>&1;
  #
  #
  echo -e "${GREEN}  Устанавливаем Prometheus${NC}";
  helm upgrade -i prometheus-community prometheus-community/kube-prometheus-stack \
    -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/docs/src/samples/monitoring/kube-stack-config.yaml \
    --wait --timeout 180m || {
    echo -e "${RED}  Ошибка при установке Prometheus, установка прервана${NC}"; exit 1;
  }

EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}CloudNative-PG установлен${NC}"
echo -e "${GREEN}${NC}"
