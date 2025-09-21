#!/bin/bash
# chmod +x 3-THA-ClasterSetup.sh

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
  "${NODES[backup]}" "${NODES[vip-api]}"
)
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

VIP_INTERFACE="ens18"

#############################################
echo -e "${GREEN}ЭТАП 3: Настройка кластера${NC}"
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done
echo -e "${GREEN}    ✓ Все узлы кластера доступны${NC}"

echo -e "${GREEN}  Проверяем доступность Kubernetes API через VIP${NC}"
for i in {1..10}; do
  curl -k --max-time 2 https://"${NODES[vip-api]}":6443/version &>/dev/null && echo -e "${GREEN}    ✓ Kubernetes API доступен${NC}" && break
  echo -e "${YELLOW}    Ожидание... $((i * 10)) сек${NC}"; sleep 10
done

echo -e "${GREEN}  Ожидаем готовности всех узлов${NC}"
sleep 5
for i in {1..60}; do
  NOT_READY=$(kubectl get nodes --no-headers | grep -v ' Ready ' || true)
  [[ -z "$NOT_READY" ]] && echo -e "${GREEN}    ✓ Все узлы в статусе Ready${NC}" && break
  [[ $i -eq 60 ]] && echo -e "${RED}    ✗ Некоторые узлы не готовы:${NC}" && echo "$NOT_READY" && exit 1
  echo -e "${YELLOW}    Ожидание... $((i * 10)) сек${NC}"; sleep 10
done

echo -e "${GREEN}  Проверяем наличие необходимых пакетов${NC}"
command -v jq >/dev/null || { echo -e "${RED}    ✗ jq не установлен, установка прервана${NC}"; exit 1; }
command -v docker >/dev/null || { echo -e "${RED}    ✗ Docker не установлен, установка прервана${NC}"; exit 1; }
command -v kubectl >/dev/null || { echo -e "${RED}    ✗ kubectl не найден, установка прервана${NC}"; exit 1; }

echo -e "${GREEN}  Устанавливаем cert-manager${NC}"
helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
helm repo update &>/dev/null
CERT_MANAGER_VERSION=$(helm search repo jetstack/cert-manager --versions -o json | jq -r '.[].version' | sort -Vr | head -n1)
[ -z "${CERT_MANAGER_VERSION}" ] || [ "${CERT_MANAGER_VERSION}" = "null" ] && { echo -e "${RED}    ✗ Не удалось получить версию cert-manager${NC}"; exit 1; }
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/"${CERT_MANAGER_VERSION}"/cert-manager.crds.yaml &>/dev/null
helm upgrade -i cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --wait --timeout 10m &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки cert-manager${NC}"; exit 1; }
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m &>/dev/null
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m &>/dev/null
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=5m &>/dev/null
kubectl -n cert-manager wait --for=condition=available deployment/cert-manager --timeout=2m &>/dev/null
sleep 5

echo -e "${GREEN}  Устанавливаем kube-vip для поддержки LoadBalancer${NC}"
kubectl delete daemonset kube-vip-ds -n kube-system --ignore-not-found >/dev/null
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml >/dev/null
VIP_VERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r '.[].tag_name' | sort -Vr | head -n1)
[ -z "${VIP_VERSION}" ] || [ "${VIP_VERSION}" = "null" ] && { echo -e "${RED}    ✗ Не удалось получить версию kube-vip${NC}"; exit 1; }
docker run --network host --rm ghcr.io/kube-vip/kube-vip:"${VIP_VERSION}" \
  manifest daemonset \
    --interface "$VIP_INTERFACE" \
    --address "${NODES[vip-service]}" \
    --inCluster \
    --controlplane \
    --services \
    --arp \
    --leaderElection 2>/dev/null | kubectl apply -f - >/dev/null
kubectl -n kube-system rollout status ds/kube-vip-ds --timeout=300s &>/dev/null
sleep 5

echo -e "${GREEN}  Устанавливаем Metrics Server${NC}"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i metrics-server metrics-server/metrics-server \
  --namespace kube-system --create-namespace \
  --set args[0]=--kubelet-insecure-tls &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки Metrics Server${NC}"; exit 1; }
sleep 5

echo -e "${GREEN}  Устанавливаем Traefik${NC}"
mkdir -p /root/traefik
cat > /root/traefik/values.yaml <<TRAEFIK_DEAMONDSET
deployment:
  kind: DaemonSet
ingressClass:
  enabled: true
  isDefaultClass: true
securityContext:
  seccompProfile:
    type: RuntimeDefault
service:
  spec:
    externalTrafficPolicy: Local
additionalArguments:
  - --serversTransport.insecureSkipVerify=true
TRAEFIK_DEAMONDSET
helm repo add traefik https://traefik.github.io/charts --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --values /root/traefik/values.yaml \
  --set service.spec.loadBalancerIP="${NODES[vip-service]}" &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки Traefik${NC}"; exit 1; }
kubectl -n traefik rollout status ds/traefik --timeout=300s &>/dev/null
rm -rf /root/traefik
sleep 5

rm -rf /root/.kube/cache
echo -e "${GREEN}Кластер настроен${NC}"; echo -e "${GREEN}${NC}"
