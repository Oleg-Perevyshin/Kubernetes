#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 1-HA-Master.sh;
# export KUBECONFIG=/root/.kube/HomeLab_Config.yaml

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.31" [s2]="192.168.5.32" [s3]="192.168.5.33"
  [a1]="192.168.5.34" [a2]="192.168.5.35" [a3]="192.168.5.36"
  [bu]="192.168.5.39"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}" "${NODES[bu]}")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
PASSWORD="!MCMega2005!"
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 1: Подготовка мастер-узла${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Устанавливаем базовые пакеты${NC}"
mkdir -p /root/.kube && chmod 700 /root/.kube
apt-get update -y &>/dev/null
apt-get upgrade -y &>/dev/null
apt-get install nano mc curl sshpass jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y &>/dev/null
systemctl enable --now systemd-timesyncd
timedatectl set-ntp off && timedatectl set-ntp on
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Генерируем SSH-ключи для работы с машинами кластера${NC}"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
# Если ключ уже существует - удаляем его и запись в authorized_keys
if [ -f "$CLUSTER_SSH_KEY" ]; then
  OLD_PUB_KEY=$(cat "${CLUSTER_SSH_KEY}.pub")
  sed -i "/$(echo "$OLD_PUB_KEY" | sed 's/[\/&]/\\&/g')/d" /root/.ssh/authorized_keys 2>/dev/null || true
  rm -f "${CLUSTER_SSH_KEY}" "${CLUSTER_SSH_KEY}.pub"
fi
ssh-keygen -t rsa -b 4096 -f "$CLUSTER_SSH_KEY" -C "cluster" -N "" &>/dev/null
cat "${CLUSTER_SSH_KEY}.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Настраиваем SSH-клиент${NC}"
SSH_CONFIG="/root/.ssh/config"
touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"
sed -i '/^Host \*/,/^$/d' "$SSH_CONFIG"
echo -e "Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null" >> "$SSH_CONFIG"
sed -i '/^$/N;/^\n$/D' "$SSH_CONFIG"
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

# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Скачиваем RKE2${NC}"
RKE2_VERSION=$(curl -s https://api.github.com/repos/rancher/rke2/releases/latest | grep tag_name | cut -d '"' -f 4)
# RKE2_INSTALLER_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz"
RKE2_INSTALLER_URL="https://github.com/rancher/rke2/releases/download/v1.32.5%2Brke2r1/rke2.linux-amd64.tar.gz"
curl -fsSL -o "/root/.kube/rke2.linux-amd64.tar.gz" "$RKE2_INSTALLER_URL"

echo -e "${GREEN}  Передаем публичный ключ и RKE2 на узлы${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  node_name=""
  for name in "${!NODES[@]}"; do
    [[ "${NODES[$name]}" == "$node_ip" ]] && node_name="$name" && break
  done
  [[ -z "$node_name" ]] && { echo -e "${RED}  ✗ Не найдено имя для IP $node_ip, установка прервана${NC}"; exit 1; }
  ping -c 1 -W 1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел ${node_ip} недоступен, установка прервана${NC}"; exit 1; }
  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "root@$node_ip" "echo '$(cat ${CLUSTER_SSH_KEY}.pub)' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" &>/dev/null
  ssh -i "$CLUSTER_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "root@$node_ip" exit &>/dev/null || { echo -e "${RED}    ✗ Ошибка SSH подключения к $node_ip, установка прервана${NC}"; exit 1; }
  [[ "$node_name" != "bu" ]] && scp -i "$CLUSTER_SSH_KEY" -o StrictHostKeyChecking=no /root/.kube/rke2.linux-amd64.tar.gz "root@$node_ip:/root/" &>/dev/null
done

rm -f "/root/.kube/rke2.linux-amd64.tar.gz"
apt-get clean && apt-get autoremove -y >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"; echo -e "${GREEN}Подготовительные работы завершены${NC}"; echo -e "${GREEN}${NC}";
