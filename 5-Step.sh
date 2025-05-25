#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 5-Step.sh;

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
ARGOCD_HOST="argocd.${PREFIX_CONFIG,,}.local"

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

echo -e "${GREEN}ЭТАП 5: Установка ArgoCD${NC}"
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

  echo -e "${GREEN}  Добавляем пространство имен${NC}"
  if ! kubectl get namespace argocd-system &>/dev/null; then
    kubectl create namespace argocd-system >/dev/null
  fi

  echo -e "${GREEN}  Применением install.yaml и ожидаем готовности ArgoCD${NC}"
  kubectl apply -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null
  kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd-system  >/dev/null

  echo -e "${GREEN}  Настраиваем Ingress${NC}"
  cat <<EOL | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOL

  echo -e "${GREEN}  Создаем самоподписанный TLS-сертификат${NC}"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/argocd.key \
    -out /tmp/argocd.crt \
    -subj "/CN=${ARGOCD_HOST}" \
    -addext "subjectAltName=DNS:${ARGOCD_HOST}" &>/dev/null
  kubectl create secret tls argocd-tls -n argocd-system --key /tmp/argocd.key --cert /tmp/argocd.crt >/dev/null

  echo -e "${GREEN}  Обновляем и проверяем Ingress ArgoCD${NC}"
  kubectl patch ingress argocd -n argocd-system --type=json -p='[
    {"op": "add", "path": "/spec/tls", "value": [{
      "hosts": ["'"${ARGOCD_HOST}"'"],
      "secretName": "argocd-tls"
    }]}
  ]'  >/dev/null
  kubectl get ingress -n argocd-system >/dev/null

  echo -e "${YELLOW}  Логин: admin | Пароль: \$(kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"
EOF
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}${NC}"
echo -e "${GREEN}ArgoCD установлен и доступен по адресу: https://${ARGOCD_HOST}${NC}"
echo -e "${GREEN}${NC}"
