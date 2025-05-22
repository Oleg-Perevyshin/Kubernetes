#!/bin/bash

# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)

# Имя пользователя, имя файла SSH сертификата и набор адресов
USER="poe"
CERT_NAME="id_rsa_master"
PASSWORD="MCMega2005!"
PREFIX_CONFIG="Home"

RANCHER_HOST="rancher.${PREFIX_CONFIG}.local"
RANCHER_PASSWORD="MCMega2005!"

# Версия Kube-VIP для развертывания
KVVERSION="v0.9.1"

# Виртуальный IP адрес (VIP)
VIP=192.168.5.20

# Диапазон адресов для Loadbalancer - это установлено на /27 в rke2-cilium-config.yaml (32-63)
LB_RANGE=192.168.5.32

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
echo -e "${GREEN}ЭТАП 3: Установка Rancher${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность сервера${NC}"
ping -c 1 -W 1 "${NODES[s1]}" &>/dev/null
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[s1]}" sudo bash <<EOF
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  echo -e "${GREEN}  Проверяем установку kubectl и helm${NC}"
  if ! command -v kubectl &>/dev/null || ! command -v helm &>/dev/null; then
    echo -e "${RED}    ✗ Необходимые инструменты не установлены, установка прервана${NC}"
    exit 1
  fi

  echo -e "${GREEN}  Устанавливаем Cert-Manager${NC}"
  helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.2/cert-manager.crds.yaml &>/dev/null
  helm upgrade -i cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --wait --timeout 30m &>/dev/null

  echo -e "${GREEN}  Устанавливаем Rancher${NC}"
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update &>/dev/null
  helm upgrade -i rancher rancher-latest/rancher \
    --namespace cattle-system --create-namespace \
    --set hostname="${RANCHER_HOST}" \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=3 \
    # --set ingress.ingressClassName=nginx \
    # --set service.port=443 \
    # --set service.targetPort=443 \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/backend-protocol"="HTTPS" \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-passthrough"="true" \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-redirect"="true" \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-connect-timeout"="30" \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-read-timeout"="1800" \
    # --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-send-timeout"="1800" \
    --wait --timeout 60m &>/dev/null

  kubectl expose deployment rancher -n cattle-system --name=rancher-lb --port=443 --type=LoadBalancer &>/dev/null

#   kubectl -n cattle-system rollout status deploy/rancher
#   kubectl -n cattle-system get deploy rancher

  echo -e "${GREEN}  Добавляем Rancher LoadBalancer, если его нет${NC}"
  if kubectl get svc rancher-lb -n cattle-system &>/dev/null; then
    echo -e "${YELLOW}    Сервис rancher-lb уже существует, удаляем...${NC}"
    kubectl delete svc rancher-lb -n cattle-system &>/dev/null
  fi
  kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system &>/dev/null

#   # while [[ $(kubectl get svc -n cattle-system 'jsonpath={..status.conditions[?(@.type=="Pending")].status}') = "True" ]]; do
#   #   sleep 5
#   #   echo -e "${YELLOW}    Ожидаем подключения LoadBalancer к сети...${NC}"
#   # done
#   kubectl get svc -n cattle-system

#   # Обновляем конфигурацию Kube с учетом VIP
#   # sudo cat /etc/rancher/rke2/rke2.yaml | sed 's/'127.0.0.1'/'$VIP'/g' > /etc/rancher/rke2/rke2.yaml
EOF

echo -e "${GREEN}Rancher успешно установлен и доступен по адресу: https://${RANCHER_HOST} | пароль ${RANCHER_PASSWORD}${NC}"
echo -e "${GREEN}${NC}"
