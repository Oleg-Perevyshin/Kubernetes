#!/bin/bash
# Вызвываем chmod +x 3-Rancher.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

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

echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 3: Установка Rancher${NC}"

# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -e;

  # Проверяем наличия kubectl и Helm
  if ! command -v kubectl &> /dev/null; then echo -e "${RED}kubectl не установлен, установка прервана${NC}"; exit 1; fi
  if ! command -v helm &> /dev/null; then echo -e "${RED}helm не установлен, установка прервана${NC}"; exit 1; fi

  # Добавляем репозиторий Rancher и Jetstack
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка добавления репозитория Rancher, установка прервана${NC}"; exit 1;
  }
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка добавления репозитория Jetstack, установка прервана${NC}"; exit 1;
  }
  helm repo update >/dev/null 2>&1;
  echo -e "${GREEN}  Репозитории Rancher и Jetstack добавлены${NC}";

  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

  # Устанавливаем Cert-Manager
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml || {
    echo -e "${RED}Ошибка применения cert-manager.crds.yaml${NC}"
    exit 1
  }
  echo -e "${GREEN}  cert-manager.crds.yaml применен${NC}";
  helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --wait --timeout 180m >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка установке Cert-Manager, установка прервана${NC}"; exit 1;
  }
  echo -e "${GREEN}  Cert-Manager установлен${NC}";

  # Устанавливаем Rancher
  helm upgrade -i rancher rancher-latest/rancher \
    --create-namespace --namespace cattle-system \
    --set hostname="rancher.rke2.local" \
    --set bootstrapPassword="MCMega2005!" \
    --set replicas=1 \
    --wait --timeout 180m >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка установке Rancher, установка прервана${NC}"; exit 1;
  }

  # Ожидаем готовности подов Rancher
  echo -e "${GREEN}  Ожидаем готовности подов Rancher...${NC}";
  if ! kubectl -n cattle-system wait --for=condition=available --timeout=5m deployment/rancher >/dev/null 2>&1; then
    echo -e "${RED}  Rancher не готов за отведенное время${NC}"
    kubectl -n cattle-system get pods >/dev/null 2>&1 || { echo -e "${RED}  Ошибка получения состояния подов${NC}"; }
    exit 1;
  fi

  echo -e "${GREEN}${NC}"; echo -e "${GREEN}Rancher установлен | Адрес: https://rancher.rke2.local | Пароль: MCMega2005!${NC}";
EOF
echo -e "${GREEN}${NC}"
