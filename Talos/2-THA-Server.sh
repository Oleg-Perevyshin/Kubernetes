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
echo -e "${GREEN}ЭТАП 2: Создание кластера${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done
# ----------------------------------------------------------------------------------------------- #
cat > patch.yaml <<'PATCH'
machine:
  network:
    nameservers: [8.8.8.8, 1.1.1.1]
  install:
    disk: /dev/sda
  time:
    servers: [0.by.pool.ntp.org, 1.by.pool.ntp.org, 2.by.pool.ntp.org]
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
PATCH
# ----------------------------------------------------------------------------------------------- #
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
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Генерируем патчи и итоговые yaml файлы для серверных нод${NC}"
for node in s1 s2 s3; do
  cat > ${node}.patch <<PATCH_SERVER
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
PATCH_SERVER
done
for node in s1 s2 s3; do
  talosctl machineconfig patch controlplane.yaml --patch @${node}.patch --output ${node}.yaml
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Генерируем патчи и итоговые yaml файлы для агентских нод${NC}"
for node in a1 a2 a3; do
  cat > ${node}.patch <<PATCH_AGENT
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
  kubelet:
    nodeLabels:
      worker: "true"
      longhorn: "true"
PATCH_AGENT
done
for node in a1 a2 a3; do
  talosctl machineconfig patch worker.yaml --patch @${node}.patch --output ${node}.yaml
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Применяем конфигурации${NC}"
for node in s1 s2 s3 a1 a2 a3; do
  echo -e "${GREEN}  → Применяем конфиг на ${HOSTNAMES[$node]} (${NODES[$node]})${NC}"
  talosctl apply-config --insecure -n "${NODES[$node]}" --file ${node}.yaml
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Удаляем временные файлы${NC}"
rm -f s1.yaml s2.yaml s3.yaml a1.yaml a2.yaml a3.yaml
rm -f s1.patch s2.patch s3.patch a1.patch a2.patch a3.patch
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Bootstrap controlplane${NC}"
talosctl bootstrap --nodes "${NODES[s1]}" --endpoints "${NODES[s1]}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Получение kubeconfig${NC}"
talosctl kubeconfig /root/.kube/config --nodes "${NODES[s1]}" --endpoints "${NODES[s1]}"
chmod 600 /root/.kube/config
echo -e "${GREEN}    ✓ kubeconfig сохранён в /root/.kube/config${NC}"

echo -e "${GREEN}Кластер создан${NC}"; echo -e "${GREEN}${NC}"
