#!/bin/bash
# Вызвываем chmod +x 6-ArgoCD.sh; из командной строки чтоб сделать файл исполняемым

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
ARGOCD_HOST="argocd.${PREFIX_CONFIG}.local"

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
echo -e "${GREEN}ЭТАП 5: Установка ArgoCD${NC}"
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
  echo -e "${GREEN}  Добавляем пространство имен для ArgoCD${NC}";
  if ! kubectl get namespace argocd >/dev/null 2>&1; then
    echo -e "${GREEN}  Добавляем пространство имен для ArgoCD${NC}";
    kubectl create namespace argocd >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка создания пространства имен${NC}"
      exit 1
    }
  fi
  #
  #
  echo -e "${GREEN}  Применением ArgoCD install.yaml${NC}";
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка применения ArgoCD install.yaml${NC}"
    exit 1
  }
  #
  #
  echo -e "${GREEN}  Создаем сервис для доступа к ArgoCD${NC}";
  kubectl expose service argocd-server --type=NodePort --name=argocd-server --namespace=argocd --port=443 --target-port=443 || {
    echo -e "${RED}  Ошибка создания сервиса${NC}"
    exit 1
  }
EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ArgoCD установлен${NC}"
echo -e "${GREEN}${NC}"
