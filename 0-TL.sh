#!/bin/bash
# chmod +x talos-cluster.sh

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.71" [s2]="192.168.5.72" [s3]="192.168.5.73"
  [a1]="192.168.5.74" [a2]="192.168.5.75" [a3]="192.168.5.76"
  [bu]="192.168.5.79" [vip]="192.168.5.80"
)
declare -A HOSTNAMES=(
  [s1]="s1" [s2]="s2" [s3]="s3"
  [a1]="a1" [a2]="a2" [a3]="a3"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")

set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}  Очищаем старые конфиги Talos${NC}"
rm -f secrets.yaml talosconfig controlplane.yaml worker.yaml patch.yaml
rm -f s1.yaml s2.yaml s3.yaml a1.yaml a2.yaml a3.yaml
rm -f s1.patch s2.patch s3.patch a1.patch a2.patch a3.patch
rm -rf /root/cilium /root/traefik


echo -e "${GREEN}ЭТАП 1: Подготовка мастер-узла${NC}"
mkdir -p /root/.kube && chmod 700 /root/.kube
apt-get update -y &>/dev/null
apt-get upgrade -y &>/dev/null
apt-get install nano mc curl jq systemd-timesyncd -y &>/dev/null
systemctl enable --now systemd-timesyncd
timedatectl set-ntp off && timedatectl set-ntp on
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем KUBECTL${NC}"
CURRENT_KUBE_VERSION=$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}' | sed 's/^v//' || echo "0.0.0")
LATEST_KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
if [ "$(printf '%s\n' "$LATEST_KUBE_VERSION" "$CURRENT_KUBE_VERSION" | sort -V | head -n1)" != "$LATEST_KUBE_VERSION" ]; then
 curl -fsSL "https://dl.k8s.io/release/v${LATEST_KUBE_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
 chmod +x /usr/local/bin/kubectl
 echo -e "${GREEN}    ✓ KUBECTL установлен, версия $LATEST_KUBE_VERSION${NC}"
else
 echo -e "${GREEN}    ✓ KUBECTL уже установлен, версия $CURRENT_KUBE_VERSION${NC}"
fi

echo -e "${GREEN}  Проверяем HELM${NC}"
CURRENT_HELM_VERSION=$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print $2}' | sed 's/^v//' || echo "0.0.0")
LATEST_HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
if [ "$(printf '%s\n' "$LATEST_HELM_VERSION" "$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "$LATEST_HELM_VERSION" ]; then
 curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null
 echo -e "${GREEN}    ✓ HELM установлен, версия $LATEST_HELM_VERSION${NC}"
else
 echo -e "${GREEN}    ✓ HELM уже установлен, версия $CURRENT_HELM_VERSION${NC}"
fi

echo -e "${GREEN}  Проверяем Talosctl${NC}"
curl -sL https://talos.dev/install | sh &>/dev/null

echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done


#############################################
echo -e "${GREEN}ЭТАП 2: Генерация базового патча и конфигов${NC}"
cat > patch.yaml <<'PATCH'
machine:
  network:
    nameservers:
      - 8.8.8.8
      - 1.1.1.1
  install:
    disk: /dev/sda
  time:
    servers:
      - 0.by.pool.ntp.org
      - 1.by.pool.ntp.org
      - 2.by.pool.ntp.org
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
PATCH

echo -e "${GREEN}  Определяем последнюю версию Kubernetes${NC}"
LATEST_KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
if [[ -z "$LATEST_KUBE_VERSION" || "$LATEST_KUBE_VERSION" == "0.0.0" ]]; then
  echo -e "${RED}    ✗ Не удалось получить последнюю версию Kubernetes${NC}"; exit 1;
fi
echo -e "${GREEN}    ✓ Последняя версия Kubernetes: $LATEST_KUBE_VERSION${NC}"

echo -e "${GREEN}  Генерируем secrets.yaml, talosconfig и базовые конфиги${NC}"
talosctl gen secrets -o secrets.yaml
talosctl gen config \
  --kubernetes-version "$LATEST_KUBE_VERSION" \
  --with-secrets secrets.yaml \
  HomeLab https://${NODES[vip]}:6443 \
  --config-patch @patch.yaml \
  --force


#############################################
echo -e "${GREEN}ЭТАП 3: Генерация патчей для нод${NC}"
for node in s1 s2 s3; do
  cat > ${node}.patch <<PATCH
machine:
  network:
    hostname: ${HOSTNAMES[$node]}
    interfaces:
      - interface: ens18
        dhcp: false
        addresses:
          - ${NODES[$node]}/24
        vip:
          ip: ${NODES[vip]}
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.5.1
PATCH
done

for node in a1 a2 a3; do
  cat > ${node}.patch <<PATCH
machine:
  network:
    hostname: ${HOSTNAMES[$node]}
    interfaces:
      - interface: ens18
        dhcp: false
        addresses:
          - ${NODES[$node]}/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.5.1
PATCH
done

#############################################
echo -e "${GREEN}ЭТАП 4: Генерация финальных конфигов и применение${NC}"
for node in s1 s2 s3; do
  talosctl machineconfig patch controlplane.yaml --patch @${node}.patch --output ${node}.yaml
done

for node in a1 a2 a3; do
  talosctl machineconfig patch worker.yaml --patch @${node}.patch --output ${node}.yaml
done

for node in s1 s2 s3 a1 a2 a3; do
  echo -e "${GREEN}  → Применяем конфиг на ${HOSTNAMES[$node]} (${NODES[$node]})${NC}"
  talosctl apply-config --insecure -n ${NODES[$node]} --file ${node}.yaml
done

echo -e "${GREEN}  Удаляем временные файлы${NC}"
rm -f s1.yaml s2.yaml s3.yaml a1.yaml a2.yaml a3.yaml
rm -f s1.patch s2.patch s3.patch a1.patch a2.patch a3.patch

# #############################################
echo -e "${GREEN}ЭТАП 5: Bootstrap controlplane${NC}"
talosctl bootstrap --nodes ${NODES[s1]} --endpoints ${NODES[s1]}

# #############################################
echo -e "${GREEN}ЭТАП 6: Получение kubeconfig${NC}"
talosctl kubeconfig /root/.kube/config --nodes ${NODES[s1]} --endpoints ${NODES[s1]}
chmod 600 /root/.kube/config
echo -e "${GREEN}    ✓ kubeconfig сохранён в /root/.kube/config${NC}"


#############################################
echo -e "${GREEN}ЭТАП 8: Настройка Cilium${NC}"
mkdir -p /root/cilium
cat > /root/cilium/ippool.yaml <<'EOF'
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 192.168.5.80/32
EOF

# l2-announcement-policy.yaml
cat > /root/cilium/l2-announcement-policy.yaml <<'EOF'
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
EOF

# values.yaml
cat > /root/cilium/values.yaml <<'EOF'
ipam:
  mode: kubernetes
kubeProxyReplacement: true
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
    cleanCiliumState:
      - NET_ADMIN
      - SYS_ADMIN
      - SYS_RESOURCE
cgroup:
  autoMount:
    enabled: false
  hostRoot: /sys/fs/cgroup
k8sServiceHost: 192.168.5.80
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
EOF

# Установка Cilium
helm repo add cilium https://helm.cilium.io --force-update
helm repo update
helm upgrade -i cilium cilium/cilium \
  --version 1.18.1 \
  --namespace kube-system \
  --values /root/cilium/values.yaml

echo -e "${GREEN}  Ждём готовности Cilium${NC}"
kubectl -n kube-system rollout status ds/cilium --timeout=300s


#############################################
echo -e "${GREEN}ЭТАП 9: Установка Metrics Server${NC}"
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server --force-update
helm repo update
helm upgrade -i metrics-server metrics-server/metrics-server \
  --namespace kube-system --create-namespace \
  --set args={--kubelet-insecure-tls}

rm -rf /root/cilium


#############################################
echo -e "${GREEN}ЭТАП 10: Установка Traefik Kubernetes Ingress${NC}"
mkdir -p /root/traefik
cat > /root/traefik/values.yaml <<'EOF'
deployment:
  kind: DaemonSet
service:
  labels:
    color: blue
  spec:
    externalTrafficPolicy: Local
additionalArguments:
  - --serversTransport.insecureSkipVerify=true
EOF

helm repo add traefik https://traefik.github.io/charts --force-update
helm repo update
helm upgrade -i traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --values /root/traefik/values.yaml

echo -e "${GREEN}  Ждём готовности Traefik${NC}"
kubectl -n traefik rollout status ds/traefik --timeout=300s

rm -rf /root/traefik
