#!/bin/bash
# chmod +x 2-THA-Server.sh

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.21" [s2]="192.168.5.22" [s3]="192.168.5.23"
  [a1]="192.168.5.24" [a2]="192.168.5.25" [a3]="192.168.5.26"
  [bu]="192.168.5.29" [vip]="192.168.5.30"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'


#############################################
echo -e "${GREEN}ЭТАП 3: Настройка кластера${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Подготавливаем файлы для настройки Cilium${NC}"
mkdir -p /root/cilium
cat > /root/cilium/ippool.yaml <<'IPPOOL'
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 192.168.5.80/32
IPPOOL

# l2-announcement-policy.yaml
cat > /root/cilium/l2-announcement-policy.yaml <<'L2AP'
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  serviceSelector:
    matchLabels:
      color: blue
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  interfaces:
    - ens18
  externalIPs: true
  loadBalancerIPs: true
L2AP

# values.yaml
cat > /root/cilium/values.yaml <<'VALUES'
ipam:
  mode: kubernetes
kubeProxyReplacement: true
securityContext:
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
k8sServiceHost: ${NODES[vip]}
k8sServicePort: 6443
l2announcements:
  enabled: true
devices: ens18
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      hosts:
        - hubble.poe-gw.keenetic.pro
VALUES

echo -e "${GREEN}  Устанавливаем Cilium и ожидаем готовности${NC}"
helm repo add cilium https://helm.cilium.io --force-update
helm repo update
LATEST_CILIUM_VERSION=$(helm search repo cilium/cilium --versions | awk 'NR==2 {print $2}')
helm upgrade -i cilium cilium/cilium \
  --version "$LATEST_CILIUM_VERSION" \
  --namespace kube-system  --create-namespace \
  --values /root/cilium/values.yaml

echo -e "${GREEN}  Ждём готовности Cilium${NC}"
kubectl -n kube-system rollout status ds/cilium --timeout=300s

rm -rf /root/cilium


#############################################
# echo -e "${GREEN}ЭТАП 9: Установка Metrics Server${NC}"
# helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update
# helm repo update
# helm upgrade -i metrics-server metrics-server/metrics-server \
#   --namespace kube-system --create-namespace \
#   --set args={--kubelet-insecure-tls}


# #############################################
# echo -e "${GREEN}ЭТАП 10: Установка Traefik Kubernetes Ingress${NC}"
# mkdir -p /root/traefik
# cat > /root/traefik/values.yaml <<'EOF'
# deployment:
#   kind: DaemonSet
# service:
#   labels:
#     color: blue
#   spec:
#     externalTrafficPolicy: Local
# additionalArguments:
#   - --serversTransport.insecureSkipVerify=true
# EOF

# helm repo add traefik https://traefik.github.io/charts --force-update
# helm repo update
# helm upgrade -i traefik traefik/traefik \
#   --namespace traefik --create-namespace \
#   --values /root/traefik/values.yaml

# echo -e "${GREEN}  Ждём готовности Traefik${NC}"
# kubectl -n traefik rollout status ds/traefik --timeout=300s

# rm -rf /root/traefik
