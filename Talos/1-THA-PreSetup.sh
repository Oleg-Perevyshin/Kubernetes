#!/bin/bash
# chmod +x 1-THA-PreSetup.sh

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
echo -e "${GREEN}ЭТАП 1: Подготовка мастер-узла${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Очищаем старые конфиги Talos${NC}"
rm -f secrets.yaml talosconfig controlplane.yaml worker.yaml patch.yaml
rm -f s1.yaml s2.yaml s3.yaml a1.yaml a2.yaml a3.yaml
rm -f s1.patch s2.patch s3.patch a1.patch a2.patch a3.patch
rm -rf /root/cilium /root/traefik

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

echo -e "${GREEN}Мастер-узел подготовлен${NC}"; echo -e "${GREEN}${NC}"