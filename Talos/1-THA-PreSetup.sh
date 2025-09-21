#!/bin/bash
# chmod +x 1-THA-PreSetup.sh
#
set -euo pipefail
# shellcheck disable=SC2034
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

KUBERNETES_VERSION="1.33.5"

#############################################
echo -e "${GREEN}ЭТАП 1: Подготовка мастер-узла${NC}"
# ----------------------------------------------------------------------------------------------- #
mkdir -p /root/.kube && chmod 700 /root/.kube
apt-get update >/dev/null
apt-get upgrade -y >/dev/null
apt-get install nano mc curl jq git systemd-timesyncd apache2-utils -y >/dev/null
systemctl enable --now systemd-timesyncd && systemctl restart systemd-timesyncd
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq &>/dev/null
chmod +x /usr/bin/yq

# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем Docker${NC}"
if curl -fsSL https://get.docker.com | sh &>/dev/null \
   && systemctl enable --now docker.service &>/dev/null \
   && systemctl enable --now containerd.service &>/dev/null \
   && command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "неизвестна")
    echo -e "${GREEN}    ✓ Docker установлен, версия $DOCKER_VERSION${NC}"
else
    echo -e "${RED}    ✗ Ошибка установки Docker${NC}"; exit 1;
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем KUBECTL${NC}"
curl -fsSL "https://dl.k8s.io/release/v$KUBERNETES_VERSION/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl
echo -e "${GREEN}    ✓ KUBECTL установлен, версия $KUBERNETES_VERSION${NC}"

# CURRENT_KUBE_VERSION=$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}' | sed 's/^v//' || echo "0.0.0")
# LATEST_KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
# if [ "$(printf '%s\n' "$LATEST_KUBE_VERSION" "$CURRENT_KUBE_VERSION" | sort -V | head -n1)" != "$LATEST_KUBE_VERSION" ]; then
  # curl -fsSL "https://dl.k8s.io/release/v$LATEST_KUBE_VERSION/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
#   chmod +x /usr/local/bin/kubectl
#   echo -e "${GREEN}    ✓ KUBECTL установлен, версия $LATEST_KUBE_VERSION${NC}"
# else
#   echo -e "${GREEN}    ✓ KUBECTL установлен, версия $CURRENT_KUBE_VERSION${NC}"
# fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем HELM${NC}"
CURRENT_HELM_VERSION=$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print $2}' | sed 's/^v//' || echo "0.0.0")
LATEST_HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
if [ "$(printf '%s\n' "$LATEST_HELM_VERSION" "$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "$LATEST_HELM_VERSION" ]; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
  echo -e "${GREEN}    ✓ HELM установлен, версия $LATEST_HELM_VERSION${NC}"
else
  echo -e "${GREEN}    ✓ HELM установлен, версия $CURRENT_HELM_VERSION${NC}"
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем TALOSCTL${NC}"
CURRENT_TALOSCTL_VERSION=$(talosctl version --client | awk '/Tag:/ {print $2}' | sed 's/^v//' || echo "0.0.0")
LATEST_TALOSCTL_VERSION=$(curl -fsSL https://api.github.com/repos/siderolabs/talos/releases/latest | jq -r '.tag_name' | sed 's/^v//')
if [ "$(printf '%s\n' "$LATEST_TALOSCTL_VERSION" "$CURRENT_TALOSCTL_VERSION" | sort -V | head -n1)" != "$LATEST_TALOSCTL_VERSION" ]; then
  curl -fsSL "https://github.com/siderolabs/talos/releases/download/v$LATEST_TALOSCTL_VERSION/talosctl-linux-amd64" -o /usr/local/bin/talosctl
  chmod +x /usr/local/bin/talosctl
  echo -e "${GREEN}    ✓ TALOSCTL установлен, версия $LATEST_TALOSCTL_VERSION${NC}"
else
  echo -e "${GREEN}    ✓ TALOSCTL установлен, версия $CURRENT_TALOSCTL_VERSION${NC}"
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}Мастер-узел подготовлен${NC}"; echo -e "${GREEN}${NC}"


# echo -e "${GREEN}  Настраиваем Backup-узел${NC}"
# apt-get install nano mc nfs-kernel-server systemd-timesyncd -y &>/dev/null
# systemctl enable --now systemd-timesyncd
# timedatectl set-ntp off && timedatectl set-ntp on
# mkdir -p /mnt/longhorn_backups
# chown nobody:nogroup /mnt/longhorn_backups
# chmod 777 /mnt/longhorn_backups
# sed -i '\#/mnt/longhorn_backups#d' /etc/exports
# echo '/mnt/longhorn_backups 192.168.5.0/24(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
# exportfs -a
# systemctl restart nfs-kernel-server