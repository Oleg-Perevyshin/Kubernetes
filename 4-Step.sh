#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 4-Step.sh;

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
CERT_NAME="id_rsa_cluster"
PREFIX_CONFIG="Home"
RANCHER_HOST="rancher.${PREFIX_CONFIG,,}.local"
RANCHER_PASSWORD="MCMega2005!"

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
echo -e "${GREEN}  Проверяем доступность всех узлов${NC}"
for node in "${NODES[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}    ✗ Узел $node недоступен, установка прервана${NC}"
    exit 1
  }
done

echo -e "${GREEN}  Проверяем сертификат${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден${NC}"
  exit 1
fi

ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" bash <<EOF
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  echo -e "${GREEN}  Добавляем репозитории Rancher и Jetstack${NC}"
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update &>/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория Rancher, установка прервана${NC}"
    exit 1
  }
  helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория Jetstack, установка прервана${NC}"
    exit 1
  }

  echo -e "${GREEN}  Применяем cert-manager.crds.yaml и устанавливаем Cert-Manager${NC}"
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/latest/download/cert-manager.crds.yaml &>/dev/null
  helm upgrade -i cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --wait --timeout 180m &>/dev/null

  echo -e "${GREEN}  Устанавливаем Rancher${NC}"
  helm upgrade -i rancher rancher-latest/rancher \
    --create-namespace --namespace cattle-system \
    --set hostname="${RANCHER_HOST}" \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=3 \
    --set ingress.ingressClassName=nginx \
    --set service.port=443 \
    --set service.targetPort=443 \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/backend-protocol"="HTTPS" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-passthrough"="true" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/ssl-redirect"="true" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-connect-timeout"="30" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-read-timeout"="1800" \
    --set-string ingress.extraAnnotations."nginx\.ingress\.kubernetes\.io/proxy-send-timeout"="1800" \
    --wait --timeout 180m &>/dev/null

  echo -e "${GREEN}  Ожидаем готовности подов Rancher${NC}"
  kubectl -n cattle-system rollout status deployment/rancher --timeout=10m

  echo -e "${GREEN}  Проверяем Ingress Rancher${NC}"
  kubectl patch ingress rancher -n cattle-system --type=json -p='[
    {"op": "replace", "path": "/spec/rules/0/http/paths/0/backend/service/port/number", "value": 443}
  ]'
  kubectl get ingress -n cattle-system rancher -o wide
  echo -e "${YELLOW}  Логин: admin | Пароль: ${RANCHER_PASSWORD}${NC}"
EOF
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Rancher успешно установлен и доступен по адресу: https://${RANCHER_HOST}${NC}"
echo -e "${GREEN}${NC}"
