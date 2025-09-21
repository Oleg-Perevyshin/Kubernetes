#!/bin/bash
# chmod +x 5-THA-Longhorn.sh

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

LONGHORN_PORT=30200

#############################################
echo -e "${GREEN}ЭТАП 5: Установка Longhorn${NC}"
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done

# echo -e "${GREEN}  Удаляем Longhorn${NC}"
# helm uninstall longhorn --namespace longhorn-system >/dev/null || true
# kubectl -n longhorn-system delete all --all --ignore-not-found >/dev/null
# kubectl -n longhorn-system delete pvc --all --ignore-not-found >/dev/null
# kubectl -n longhorn-system delete pv --all --ignore-not-found >/dev/null
# kubectl -n longhorn-system delete secrets --all --ignore-not-found >/dev/null
# kubectl -n longhorn-system delete configmap --all --ignore-not-found >/dev/null
# kubectl -n longhorn-system delete serviceaccount --all --ignore-not-found >/dev/null
# kubectl get crd -o name | grep '\.longhorn\.io' | xargs -r kubectl delete --ignore-not-found >/dev/null
# NS_JSON="/root/longhorn-ns.json"
# if kubectl get namespace longhorn-system &>/dev/null; then
#   kubectl get namespace longhorn-system -o json > "$NS_JSON"
#   sed -i '/"finalizers"/,/]/d' "$NS_JSON"
#   kubectl replace --raw "/api/v1/namespaces/longhorn-system/finalize" -f "$NS_JSON" &>/dev/null || true
#   rm -f "$NS_JSON"
# fi
# kubectl get namespace longhorn-system &>/dev/null || echo -e "${YELLOW}    Namespace longhorn-system удалён${NC}"

echo -e "${GREEN}  Устанавливаем Longhorn${NC}"
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl label namespace longhorn-system pod-security.kubernetes.io/audit=privileged --overwrite >/dev/null
kubectl label namespace longhorn-system pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null

cat > /root/longhorn.yaml <<LONGHORN
defaultBackupStore:
  backupTarget: "nfs://${NODES[backup]}:/mnt/longhorn_backups"
defaultSettings:
  systemManagedComponentsNodeSelector:
    worker: "true"
    longhorn: "true"
service:
  ui:
    port: 80
    targetPort: 8000
LONGHORN

helm upgrade -i longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --values /root/longhorn.yaml \
  --wait --timeout 10m >/dev/null || { echo -e "${RED}    ✗ Ошибка upgrade Longhorn${NC}"; exit 1; }
rm -f /root/longhorn.yaml
kubectl -n longhorn-system rollout status deploy/longhorn-ui --timeout=10m &>/dev/null
kubectl -n longhorn-system wait --for=condition=available deploy --all --timeout=10m &>/dev/null

echo -e "${GREEN}  Создаём Service${NC}"
cat <<SERVICE | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: longhorn-lb
  namespace: longhorn-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip-service]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip-service]}"
  ports:
    - name: longhorn
      port: ${LONGHORN_PORT}
      targetPort: 80
      protocol: TCP
  selector:
    app: longhorn-ui
SERVICE
echo -e "${GREEN}  Локальный доступ: http://${NODES[vip-service]}:${LONGHORN_PORT}"

rm -rf /root/.kube/cache
echo -e "${GREEN}Longhorn установлен${NC}"; echo -e "${GREEN}${NC}"
