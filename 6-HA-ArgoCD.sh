#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 6-HA-ArgoCD.sh;

# Определяем машины кластера
declare -A NODES=(
 [vip]="192.168.5.40"
 [s1]="192.168.5.31"
 [s2]="192.168.5.32"
 [s3]="192.168.5.33"
 [a1]="192.168.5.34"
 [a2]="192.168.5.35"
 [a3]="192.168.5.36"
)

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="/root/.ssh/id_rsa_cluster"
ARGOCD_HOST="argocd.poe-gw.keenetic.pro"
ARGOCD_PORT=30200
ARGOCD_PASSWORD="!MCMega2005!"

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
# Прекращение выполнения при любой ошибке и цвета для вывода
set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}ЭТАП 6: Установка ArgoCD${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -i "$CERT_NAME" "root@${NODES[s1]}" bash <<ARGOCD
 set -euo pipefail
 export DEBIAN_FRONTEND=noninteractive
 export PATH=$PATH:/usr/local/bin

 echo -e "${GREEN}  Удаляем предыдущую установку ArgoCD${NC}"
 kubectl delete svc argocd-loadbalancer -n argocd &>/dev/null || true
 kubectl delete -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml &>/dev/null || true

 echo -e "${GREEN}  Устанавливаем ArgoCD${NC}"
 kubectl create namespace argocd-system &>/dev/null || true
 kubectl apply -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml &>/dev/null || true

 echo -e "${GREEN}  Создаем Service для доступа через порт ${ARGOCD_PORT}${NC}"
 cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Service
metadata:
 name: argocd-loadbalancer
 namespace: argocd-system
 annotations:
   service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
spec:
 type: LoadBalancer
 loadBalancerIP: ${NODES[vip]}
 ports:
 - name: http
   port: ${ARGOCD_PORT}
   targetPort: 8080
   protocol: TCP
 selector:
   app.kubernetes.io/name: argocd-server
EOF

 echo -e "${GREEN}  Отключаем TLS и перезапускаем сервер${NC}"
 kubectl patch configmap argocd-cmd-params-cm -n argocd-system --type merge \
   -p '{"data":{"server.insecure": "true"}}' >/dev/null
 kubectl -n argocd-system rollout restart deployment argocd-server  >/dev/null
 kubectl -n argocd-system rollout status deploy/argocd-server --timeout=10m >/dev/null
 kubectl -n argocd-system wait --for=condition=available deployment/argocd-server --timeout=1m >/dev/null

 echo -e "${GREEN}  Текущие данные входа: Логин: admin | Пароль: \$(kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"
 echo -e "${GREEN}  Смените на Логин: admin | Пароль: ${ARGOCD_PASSWORD}${NC}"
 echo -e "${GREEN}  Локальный доступ: http://${NODES[vip]}:${ARGOCD_PORT}${NC}"
 echo -e "${GREEN}  Внешний доступ:   https://${ARGOCD_HOST}${NC}"
ARGOCD
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ArgoCD установлен${NC}"
echo -e "${GREEN}${NC}"
