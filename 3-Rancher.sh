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
RANCHER_HOST="rancher.${PREFIX_CONFIG}.local"
RANCHER_PASSWORD="MCMega2005!"

# Машины кластера
if [[ "$PREFIX_CONFIG" == "home" ]]; then
  declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
elif [[ "$PREFIX_CONFIG" == "office" ]]; then
  declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
else
  echo -e "${RED}Неизвестный кластер $PREFIX_CONFIG, установка прервана${NC}"
  exit 1
fi

echo -e "${GREEN}ЭТАП 3: Установка Rancher${NC}"
echo -e "${GREEN}[1/8] Проверяем доступность сервера${NC}"
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
  echo -e "${GREEN}[2/8] Проверяем установку kubectl и Helm${NC}"
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
  echo -e "${GREEN}[3/8] Добавляем репозитории Rancher и Jetstack${NC}"
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка добавления репозитория Rancher, установка прервана${NC}"
    exit 1
  }
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка добавления репозитория Jetstack, установка прервана${NC}"
    exit 1
  }
  helm repo update >/dev/null 2>&1
  echo -e "${GREEN}  ✓ Репозитории Rancher и Jetstack добавлены${NC}"
  #
  #
  echo -e "${GREEN}[4/8] Применяем cert-manager.crds.yaml${NC}"
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка применения cert-manager.crds.yaml${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ cert-manager.crds.yaml применен${NC}"
  #
  #
  echo -e "${GREEN}[5/8] Устанавливаем Cert-Manager${NC}"
  helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --wait --timeout 180m || {
    echo -e "${RED}  Ошибка установки Cert-Manager, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Cert-Manager успешно установлен${NC}"
  #
  #
  echo -e "${GREEN}[6/8] Устанавливаем Rancher${NC}"
  helm upgrade -i rancher rancher-latest/rancher \
    --create-namespace --namespace cattle-system \
    --set hostname="${RANCHER_HOST}" \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=1 \
    --set ingress.ingressClassName=nginx \
    --set service.port=443 \
    --set service.targetPort=443 \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/backend-protocol"="HTTPS" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-passthrough"="true" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-redirect"="true" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-connect-timeout"="30" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-read-timeout"="1800" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-send-timeout"="1800" \
    --wait --timeout 180m || {
      echo -e "${RED}  Ошибка установки Rancher, установка прервана${NC}"
      exit 1
  }
  echo -e "${GREEN}  ✓ Rancher установлен${NC}"
  #
  #
  echo -e "${GREEN}[7/8] Ожидаем готовности подов Rancher${NC}"
  if ! kubectl -n cattle-system wait --for=condition=available --timeout=5m deployment/rancher >/dev/null 2>&1; then
    echo -e "${RED}  Rancher не готов за отведенное время${NC}"
    kubectl -n cattle-system get pods >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка получения состояния подов${NC}"
    }
    exit 1
  fi
  echo -e "${GREEN}  ✓ Поды Rancher запущены${NC}"
  #
  #
  echo -e "${GREEN}[8/8] Проверяем Ingress Rancher${NC}"
  kubectl patch ingress rancher -n cattle-system --type=json -p='[
    {"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 443}
  ]'
  kubectl get ingress rancher -n cattle-system -o wide || {
    echo -e "${RED}  Ошибка проверки Ingress${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Ingress Rancher успешно запущен${NC}"

  echo -e "${YELLOW}  Логин: admin | Пароль: ${RANCHER_PASSWORD}${NC}"
EOF

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Rancher успешно установлен и доступен по адресу: https://${RANCHER_HOST}${NC}"
echo -e "${GREEN}${NC}"
