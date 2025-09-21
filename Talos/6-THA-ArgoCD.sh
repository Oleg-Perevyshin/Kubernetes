#!/bin/bash
# chmod +x 6-THA-ArgoCD.sh

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

ARGOCD_HOST="argocd.poe-gw.keenetic.pro"
ARGOCD_PORT=30300

#############################################
echo -e "${GREEN}ЭТАП 6: Установка ArgoCD${NC}"
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done

echo -e "${GREEN}  Удаляем предыдущую установку${NC}"
kubectl delete svc argocd-lb -n argocd &>/dev/null || true
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml &>/dev/null || true
sleep 5

echo -e "${GREEN}  Устанавливаем ArgoCD${NC}"
helm repo add argo https://argoproj.github.io/argo-helm --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --wait --timeout 10m &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки ArgoCD${NC}"; exit 1; }
kubectl -n argocd rollout status deploy/argocd-server --timeout=10m &>/dev/null
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=2m &>/dev/null
rm -f /root/argocd.yaml
sleep 5

echo -e "${GREEN}  Создаём Service${NC}"
cat <<SERVICE | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: argocd-lb
  namespace: argocd
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip-service]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip-service]}"
  ports:
    - name: argocd
      port: ${ARGOCD_PORT}
      targetPort: 8080
      protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
SERVICE

echo -e "${GREEN}  Логин: admin | Пароль: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"
echo -e "${GREEN}  Локальный доступ: http://${NODES[vip-service]}:${ARGOCD_PORT}${NC}"
echo -e "${GREEN}  Внешний доступ: https://${ARGOCD_HOST}${NC}"

rm -rf /root/.kube/cache
echo -e "${GREEN}ArgoCD установлен${NC}"; echo -e "${GREEN}${NC}"
