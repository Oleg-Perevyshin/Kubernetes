#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 4-HA-Rancher.sh;

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [vip]="192.168.5.20"
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)
ORDERED_NODES=("${NODES[vip]}" "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
PREFIX_CONFIG="Home"
RANCHER_HOST="rancher.poe-gw.keenetic.pro"
RANCHER_PASSWORD="MCMega2005!"
RANCHER_PORT=30100

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}ЭТАП 4: Установка Rancher${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" bash <<RANCHER
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  echo -e "${GREEN}  Добавляем репозитории и устанавливаем Cert Manager${NC}"
  helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
  LATEST_CM_VERSION=\$(helm search repo jetstack/cert-manager -o json | jq -r '.[0].version')
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/\${LATEST_CM_VERSION}/cert-manager.crds.yaml >/dev/null
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version \${LATEST_CM_VERSION} \
    --wait --timeout 60m >/dev/null
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=10m >/dev/null
  kubectl -n cert-manager wait --for=condition=available deployment/cert-manager --timeout=1m >/dev/null

  echo -e "${GREEN}  Добавляем репозиторий и устанавливаем Rancher${NC}"
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update &>/dev/null
  helm upgrade -i rancher rancher-stable/rancher \
    --namespace cattle-system --create-namespace \
    --set hostname="${RANCHER_HOST}" \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=3 \
    --set service.externalPort="${RANCHER_PORT}" \
    --wait --timeout 60m >/dev/null

  echo -e "${GREEN}  Создаем Service для доступа через порт ${RANCHER_PORT}${NC}"
  cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Service
metadata:
  name: rancher-loadbalancer
  namespace: cattle-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip]}"
  ports:
  - name: https
    port: ${RANCHER_PORT}
    targetPort: 443
    protocol: TCP
  selector:
    app: rancher
EOF

  kubectl -n cattle-system rollout status deploy/rancher --timeout=10m >/dev/null
  kubectl -n cattle-system wait --for=condition=available deployment/rancher --timeout=1m >/dev/null

  kubectl patch ingress rancher -n cattle-system --type=json -p='[
    {"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 443}
  ]' >/dev/null

  echo -e "${GREEN}    Логин: admin | Пароль: ${RANCHER_PASSWORD}${NC}"
  echo -e "${GREEN}    Локальный доступ: https://${NODES[vip]}:${RANCHER_PORT}${NC}"
  echo -e "${GREEN}    Внешний доступ: https://${RANCHER_HOST}${NC}"
RANCHER
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Rancher установлен${NC}"
echo -e "${GREEN}${NC}"
