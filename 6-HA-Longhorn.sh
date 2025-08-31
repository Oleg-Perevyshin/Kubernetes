#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 6-HA-Longhorn.sh;
# Установить через Rancher (Cluster => Tools)
# Через интерфейс Longhorn отредактировать Setting -> Backup Target
# nfs://192.168.5.39:/mnt/longhorn_backups
#
# Это только альтернативный вариант!
# Конфигурация кластера
declare -A NODES=([s1]="192.168.5.31" [vip]="192.168.5.40")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
LONGHORN_HOST="longhorn.poe-gw.keenetic.pro"
LONGHORN_PORT=30300
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 6: Установка Longhorn${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" bash <<LONGHORN
  set -euo pipefail
  export PATH=\$PATH:/usr/local/bin

  echo -e "${GREEN}  Устанавливаем Longhorn...${NC}"
  helm repo add longhorn https://charts.longhorn.io --force-update &>/dev/null
  helm repo update
  LATEST_LH_VERSION=\$(helm search repo longhorn/longhorn -o json | jq -r '.[0].version')
  [ -z "\$LATEST_LH_VERSION" ] && echo -e "${RED}    ✗ Не удалось получить версию Longhorn, установка прервана${NC}" && exit 1
  helm upgrade -i longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace \
    --version \${LATEST_LH_VERSION} \
    --wait --timeout 60m
  kubectl -n longhorn-system wait --for=condition=available deployment --all --timeout=10m &>/dev/null

  echo -e "${GREEN}  Создаём LoadBalancer Service для Longhorn${NC}"
  cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Service
metadata:
  name: longhorn-frontend-lb
  namespace: longhorn-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip]}"
  ports:
    - name: http
      port: ${LONGHORN_PORT}
      targetPort: 80
      protocol: TCP
  selector:
    app: longhorn-ui
EOF
LONGHORN
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Локальный доступ: http://${NODES[vip]}:${LONGHORN_PORT}"
echo -e "${GREEN}  Внешний доступ:   https://${LONGHORN_HOST}${NC}"
echo -e "${GREEN}Longhorn установлен${NC}"; echo -e "${GREEN}${NC}";
