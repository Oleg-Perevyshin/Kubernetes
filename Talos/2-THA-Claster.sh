#!/bin/bash
# chmod +x 2-THA-Claster.sh

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
  "${NODES[backup]}"
)
CONTROLPLANE_ENDPOINTS="${NODES[s1]},${NODES[s2]},${NODES[s3]}"

set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

API_DOMAIN="k8s.poe-gw.keenetic.pro"
API_PORT=6443
VIP_INTERFACE="ens18"
KUBERNETES_VERSION="1.33.5"

#############################################
echo -e "${GREEN}ЭТАП 2: Создание кластера K8S v$KUBERNETES_VERSION${NC}"
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done

echo -e "${GREEN}  Проверяем наличие необходимых пакетов${NC}"
command -v jq >/dev/null || { echo -e "${RED}    ✗ jq не установлен, установка прервана${NC}"; exit 1; }
command -v docker >/dev/null || { echo -e "${RED}    ✗ Docker не установлен, установка прервана${NC}"; exit 1; }
command -v kubectl >/dev/null || { echo -e "${RED}    ✗ kubectl не найден, установка прервана${NC}"; exit 1; }

echo -e "${GREEN}  Генерируем базовые файлы конфигурации${NC}"
mkdir -p /root/.kube
mkdir -p /root/.talos
cat > /root/.talos/patch.yaml <<PATCH
machine:
  kernel:
    modules:
      - name: configfs
      - name: iscsi_ibft
      - name: iscsi_tcp
      - name: nbd
  network:
    nameservers: ["8.8.8.8", "1.1.1.1"]
  install:
    disk: /dev/sda
    image: factory.talos.dev/metal-installer/6de9c05336b81d95117ec9e8e30cf84b4273b9971ee797f256380b1bce503511:v1.11.1
    extraKernelArgs: ["vga=794"]
  time:
    servers: ["by.pool.ntp.org", "europe.pool.ntp.org", "pool.ntp.org"]
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  apiServer:
    certSANs: ["${NODES[vip-api]}", "${API_DOMAIN}", "127.0.0.1", "kubernetes.default.svc", "kubernetes"]
PATCH
[ -f /root/.talos/secrets.yaml ] || talosctl gen secrets -o /root/.talos/secrets.yaml
talosctl gen config poe-home-lab https://${API_DOMAIN} \
  --with-secrets /root/.talos/secrets.yaml \
  --config-patch @/root/.talos/patch.yaml \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --output-dir /root/.talos \
  --force &>/dev/null || { echo -e "${RED} ✗ Ошибка генерации файлов для Talos${NC}"; exit 1; }
rm -f /root/.talos/patch.yaml
mv -f /root/.talos/talosconfig /root/.talos/config
chmod 600 /root/.talos/config
talosctl config node "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}"
talosctl config endpoint "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}"

echo -e "${GREEN}  Генерируем файлы для ControlPlane нод${NC}"
for node in s1 s2 s3; do
  talosctl machineconfig patch /root/.talos/controlplane.yaml --patch "$(cat <<PATCH_SERVER
machine:
  network:
    hostname: "$node"
    interfaces:
      - interface: "${VIP_INTERFACE}"
        dhcp: false
        addresses: ["${NODES[$node]}/24"]
        vip:
          ip: "${NODES[vip-api]}"
        routes:
          - network: "0.0.0.0/0"
            gateway: "192.168.5.1"
PATCH_SERVER
    )" --output /root/.talos/${node}.yaml
done
rm -f /root/.talos/controlplane.yaml

echo -e "${GREEN}  Генерируем файлы для Worker нод${NC}"
for node in w1 w2 w3; do
  talosctl machineconfig patch /root/.talos/worker.yaml --patch "$(cat <<PATCH_AGENT
machine:
  network:
    hostname: "$node"
    interfaces:
      - interface: "${VIP_INTERFACE}"
        dhcp: false
        addresses: ["${NODES[$node]}/24"]
        routes:
          - network: "0.0.0.0/0"
            gateway: "192.168.5.1"
  nodeLabels:
    worker: "true"
    longhorn: "true"
PATCH_AGENT
    )" --output /root/.talos/${node}.yaml
done
rm -f /root/.talos/worker.yaml

echo -e "${GREEN}  Применяем конфигурации${NC}"
for node in s1 s2 s3 w1 w2 w3; do
  if talosctl -n "${NODES[$node]}" get machineconfig > /dev/null 2>&1; then
    echo -e "${YELLOW}    ✓ ${node} уже в рабочем состоянии, применяем patch${NC}"
    talosctl apply-config -n "${NODES[$node]}" -f /root/.talos/"${node}.yaml" -m=auto &>/dev/null
    rm -f /root/.talos/"${node}.yaml"
  else
    echo -e "${YELLOW}    ✓ ${node} в начальном состоянии, применяем insecure config${NC}"
    talosctl apply-config -i -n "${NODES[$node]}" -f /root/.talos/"${node}.yaml" &>/dev/null
    rm -f /root/.talos/"${node}.yaml"
  fi
done

echo -e "${GREEN}  Ожидаем доступности Talos API на ${NODES[s1]}${NC}"
for i in {1..60}; do
  nc -z -w2 "${NODES[s1]}" 50000 && echo -e "${GREEN}    ✓ Talos API доступен${NC}" && break
  echo -e "${YELLOW}    Ожидание... $((i * 10)) сек${NC}"; sleep 10
  [[ $i -eq 60 ]] && echo -e "${RED}    ✗ Talos API не доступен${NC}" && exit 1
done

echo -e "${GREEN}  Выполняем bootstrap по необходимости${NC}"
talosctl bootstrap -n "${NODES[s1]}" -e "$CONTROLPLANE_ENDPOINTS" >/dev/null || true

echo -e "${GREEN}  Ожидаем доступности Kubernetes API через VIP${NC}"
for i in {1..30}; do
  curl -k --max-time 2 https://"${NODES[vip-api]}":"${API_PORT}"/version &>/dev/null && echo -e "${GREEN}    ✓ Kubernetes API через VIP доступен${NC}" && break
  echo -e "${YELLOW}    Ожидание... $((i * 10)) сек${NC}"; sleep 10
  [[ $i -eq 30 ]] && echo -e "${RED}    ✗ Kubernetes API через VIP не доступен${NC}" && exit 1
done

echo -e "${GREEN}  Готовим настройки кластера для локального и удаленного доступа${NC}"
rm -f /root/.kube/config /root/.kube/config-lens
talosctl kubeconfig /root/.kube/config -n "${NODES[s1]}" -e "${NODES[vip-api]}"
cp /root/.kube/config /root/.kube/config-lens
chmod 600 /root/.kube/config /root/.kube/config-lens
kubectl --kubeconfig=/root/.kube/config config set-cluster poe-home-lab --server="https://${NODES[vip-api]}:${API_PORT}" >/dev/null
kubectl --kubeconfig=/root/.kube/config-lens config set-cluster poe-home-lab --server="https://${API_DOMAIN}" >/dev/null
echo -e "${GREEN}    ✓ kubeconfig сохранён в /root/.kube/config${NC}"

echo -e "${GREEN}  Устанавливаем Cilium${NC}"
cat > /root/cilium.yaml <<CILIUM
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
k8sServiceHost: "${NODES[vip-api]}"
k8sServicePort: "${API_PORT}"
l2announcements:
  enabled: true
devices: ["${VIP_INTERFACE}"]
CILIUM
sleep 10
helm repo add cilium https://helm.cilium.io --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i cilium cilium/cilium \
  --namespace kube-system  --create-namespace \
  --values /root/cilium.yaml >/dev/null || { echo -e "${RED}    ✗ Ошибка установки Cilium${NC}"; exit 1; }
kubectl -n kube-system rollout status ds/cilium --timeout=300s >/dev/null || { echo -e "${RED}    ✗ Ошибка установки Cilium${NC}"; exit 1; }
rm -f /root/cilium.yaml
echo -e "${GREEN}    ✓ Cilium установлен, v$(helm list -n kube-system -o json | jq -r '.[] | select(.name=="cilium") | .app_version')${NC}"

rm -rf /root/.kube/cache
echo -e "${GREEN}Кластер создан${NC}"; echo -e "${GREEN}${NC}"
