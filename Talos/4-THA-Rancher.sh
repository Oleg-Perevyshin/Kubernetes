#!/bin/bash
# chmod +x 4-THA-Rancher.sh

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.21" [s2]="192.168.5.22" [s3]="192.168.5.23" # ControlPlane
  [w1]="192.168.5.24" [w2]="192.168.5.25" [w3]="192.168.5.26" # Worker
  [backup]="192.168.5.29"                                     # Backup/Longhorn
  [vip-api]="192.168.5.30"                                    # API-сервера Talos
  [vip-service]="192.168.5.31"                                # LoadBalancer
)
ORDERED_NODES=(
  "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}"
  "${NODES[w1]}" "${NODES[w2]}" "${NODES[w3]}"
  "${NODES[backup]}" "${NODES[vip-api]}" "${NODES[vip-service]}"
)
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

RANCHER_HOST="rancher.poe-gw.keenetic.pro"
RANCHER_PORT=30100
RANCHER_PASSWORD="!MCMega2005!"

#############################################
echo -e "${GREEN}ЭТАП 4: Установка Rancher${NC}"
# ----------------------------------------------------------------------------------------------- #
rm -rf /root/rancher
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Устанавливаем Rancher${NC}"
kubectl label namespace cattle-system pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
kubectl label namespace cattle-system pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null 2>&1 || true
kubectl label namespace cattle-system pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null 2>&1 || true
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i rancher rancher-stable/rancher \
  --namespace cattle-system --create-namespace \
  --set hostname="${RANCHER_HOST}" \
  --set bootstrapPassword="${RANCHER_PASSWORD}" \
  --set replicas=3 \
  --wait --timeout 30m &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки Rancher${NC}"; exit 1; }
kubectl -n cattle-system rollout status deploy/rancher --timeout=10m &>/dev/null
kubectl -n cattle-system wait --for=condition=available deployment/rancher --timeout=2m &>/dev/null
sleep 5
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Создаём Service${NC}"
cat <<SERVICE | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: rancher-lb
  namespace: cattle-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip-service]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip-service]}"
  ports:
  - name: rancher
    port: ${RANCHER_PORT}
    targetPort: 443
    protocol: TCP
  selector:
    app: rancher
SERVICE
sleep 5

rm -rf /root/rancher
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Логин: admin | Пароль: ${RANCHER_PASSWORD}${NC}"
echo -e "${GREEN}  Локальный доступ: https://${NODES[vip-service]}:${RANCHER_PORT}${NC}"
echo -e "${GREEN}  Внешний доступ: https://${RANCHER_HOST}${NC}"

rm -rf /root/.kube/cache
echo -e "${GREEN}Rancher установлен${NC}"; echo -e "${GREEN}${NC}"
