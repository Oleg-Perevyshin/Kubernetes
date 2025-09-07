#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 5-HA-Rancher.sh;

# Конфигурация кластера
declare -A NODES=([s1]="192.168.5.31" [vip]="192.168.5.40")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
RANCHER_HOST="rancher.poe-gw.keenetic.pro"
RANCHER_PASSWORD="!MCMega2005!"
RANCHER_PORT=30100
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 5: Установка Rancher${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" bash -c "bash -s" <<RANCHER
  echo -e "${GREEN}  Устанавливаем cert-manager${NC}"
  set -euo pipefail
  export PATH=\$PATH:/usr/local/bin
  command -v jq >/dev/null || { echo -e "${RED}    ✗ jq не установлен, установка прервана${NC}"; exit 1; }
  command -v helm >/dev/null || { echo -e "${RED}    ✗ helm не найден, установка прервана${NC}"; exit 1; }
  command -v kubectl >/dev/null || { echo -e "${RED}    ✗ kubectl не найден, установка прервана${NC}"; exit 1; }
  helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
  helm repo update
  CM_VERSION=\$(helm search repo jetstack/cert-manager -o json | jq -r '.[0].version')
  [ -z "\$CM_VERSION" ] && echo -e "${RED}    ✗ Не удалось получить версию cert-manager, установка прервана${NC}" && exit 1
  kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/\$CM_VERSION/cert-manager.crds.yaml &>/dev/null
  helm upgrade -i cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version \$CM_VERSION \
    --wait --timeout 10m &>/dev/null
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m &>/dev/null
  kubectl -n cert-manager wait --for=condition=available deployment/cert-manager --timeout=2m &>/dev/null

  echo -e "${GREEN}  Устанавливаем Rancher${NC}"
  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update &>/dev/null
  helm repo update
  helm upgrade -i rancher rancher-stable/rancher \
    --namespace cattle-system --create-namespace \
    --set hostname="${RANCHER_HOST}" \
    --set bootstrapPassword="${RANCHER_PASSWORD}" \
    --set replicas=3 \
    --set service.externalPort="${RANCHER_PORT}" \
    --set ingress.enabled=true \
    --set service.type=ClusterIP \
    # --set ingress.tls.source=letsEncrypt \
    # --set letsEncrypt.email=oleg.perevyshin@gmail.com \
    # --set letsEncrypt.environment=production \
    --wait --timeout 30m &>/dev/null
       
  echo -e "${GREEN}  Создаём LoadBalancer Service для Rancher${NC}"
  cat <<SVC | kubectl apply -f - &>/dev/null
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
SVC
  kubectl -n cattle-system rollout status deploy/rancher --timeout=5m &>/dev/null
  kubectl -n cattle-system wait --for=condition=available deployment/rancher --timeout=2m &>/dev/null

  echo -e "${GREEN}  Ждём, пока kube-vip пропишет IP в LoadBalancer Service${NC}"
  for i in {1..30}; do
    if kubectl -n cattle-system get svc rancher-loadbalancer -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -qE '^[0-9]'; then
      break
    fi
    sleep 2
  done

  echo -e "${GREEN}  Настраиваем server-url для внешнего доступа${NC}"
  kubectl -n cattle-system patch settings.management.cattle.io server-url \
    --type=merge -p "{\"value\":\"https://${RANCHER_HOST}\"}" &>/dev/null || true

  echo -e "${GREEN}  Перезапускаем Rancher${NC}"
  kubectl -n cattle-system rollout restart deploy rancher &>/dev/null
  kubectl -n cattle-system rollout status deploy/rancher --timeout=5m &>/dev/null
RANCHER
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Локальный доступ: https://${NODES[vip]}:${RANCHER_PORT} (admin | ${RANCHER_PASSWORD})${NC}"
echo -e "${GREEN}  Внешний доступ:   https://${RANCHER_HOST} (admin | ${RANCHER_PASSWORD})${NC}"
echo -e "${GREEN}Rancher установлен${NC}"; echo -e "${GREEN}${NC}";

# Установить Longhorn через Rancher (Cluster => Tools)
# Через интерфейс Longhorn отредактировать Setting -> Backup Target
# nfs://192.168.5.39:/mnt/longhorn_backups