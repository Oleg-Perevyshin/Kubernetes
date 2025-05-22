#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x <file name>
# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)

# Имя пользователя, имя файла SSH сертификата и набор адресов
USER="root"
CERT_NAME="id_rsa_master"
PASSWORD="MCMega2005!"
#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
echo -e "${GREEN}ЭТАП 0: Подготовка${NC}"
rm -rf "$HOME/.kube" >/dev/null && mkdir -p "$HOME/.kube" >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем файл SSH${NC}"
SSH_CONFIG="$HOME/.ssh/config"
[ -f "$SSH_CONFIG" ] || { touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"; }
if ! grep -q "StrictHostKeyChecking" "$SSH_CONFIG"; then
  echo "StrictHostKeyChecking no" >>"$SSH_CONFIG"
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Синхронизируем время${NC}"
sudo timedatectl set-ntp off >/dev/null
sudo timedatectl set-ntp on >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем kubectl${NC}"
CURRENT_KUBE_VERSION="0.0.0"
if command -v kubectl &>/dev/null; then
  CURRENT_KUBE_VERSION=$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}' | sed 's/^v//' || echo "0.0.0")
fi
LATEST_KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
if [ -z "$CURRENT_KUBE_VERSION" ] || [ "$CURRENT_KUBE_VERSION" != "$LATEST_KUBE_VERSION" ]; then
  echo -e "${YELLOW}    Устанавливаем kubectl v${LATEST_KUBE_VERSION}${NC}"
  curl -fsSL "https://dl.k8s.io/release/v${LATEST_KUBE_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  sudo chmod +x /tmp/kubectl
  sudo mv /tmp/kubectl /usr/local/bin/
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем helm${NC}"
CURRENT_HELM_VERSION="0.0.0"
if command -v helm &>/dev/null; then
  CURRENT_HELM_VERSION=$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print $2}' | sed 's/^v//' || echo "0.0.0")
fi
LATEST_HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
if [ -z "$CURRENT_HELM_VERSION" ] || [ "$CURRENT_HELM_VERSION" != "$LATEST_HELM_VERSION" ]; then
  echo -e "${YELLOW}    Устанавливаем helm v${LATEST_HELM_VERSION}${NC}"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Настраиваем окружение${NC}"
if [ ! -f /etc/profile.d/k8s-tools.sh ] || ! grep -q '/usr/local/bin' /etc/profile.d/k8s-tools.sh; then
  echo 'export PATH=$PATH:/usr/local/bin' | sudo tee /etc/profile.d/k8s-tools.sh >/dev/null
  chmod +x /etc/profile.d/k8s-tools.sh
fi
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node in "${NODES[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}    ✗ Узел $node недоступен, установка прервана${NC}"
    exit 1
  }
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Работаем с SSH ключами${NC}"
CERT_PATH="$HOME/.ssh/$CERT_NAME"
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" &>/dev/null
  sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$CERT_PATH" "$USER@$ip" &>/dev/null
  if [[ $node == s* ]]; then
    scp -i "$CERT_PATH" "$CERT_PATH" "$CERT_PATH.pub" "$USER@$ip:/home/$USER/.ssh/" &>/dev/null
    ssh -i "$CERT_PATH" "$USER@$ip" "chmod 600 /home/$USER/.ssh/$CERT_NAME && chmod 644 /home/$USER/.ssh/$CERT_NAME.pub" &>/dev/null
  fi
done
# ----------------------------------------------------------------------------------------------- #
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  # shellcheck disable=SC2087
  ssh -q -i "$HOME/.ssh/$CERT_NAME" "$USER@$ip" sudo bash <<EOF
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}  Готовим узел $ip${NC}"
    if systemctl is-active --quiet ufw; then
      systemctl disable --now ufw
    fi

    echo -e "${GREEN}  Устанавливаем пакеты${NC}"
    apt-get update -y >/dev/null
    apt-get -o DPkg::options::="--force-confdef" \
            -o DPkg::options::="--force-confold" \
            install mc nano curl jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y >/dev/null

    echo -e "${GREEN}  Синхронизируем время${NC}"
    systemctl start systemd-timesyncd
    timedatectl set-ntp off >/dev/null
    timedatectl set-ntp on >/dev/null

    sed -i '/[[:space:]]*swap/s/^\([^#]\)/# \1/' /etc/fstab >/dev/null
    swapoff -a >/dev/null

    if [[ $node == s* ]]; then
      echo -e "${GREEN}  Проверяем kubectl${NC}"
      CURRENT_KUBE_VERSION="0.0.0"
      if command -v kubectl &>/dev/null; then
        CURRENT_KUBE_VERSION=\$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print \$3}' | sed 's/^v//' || echo "0.0.0")
      fi
      LATEST_KUBE_VERSION=\$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
      if [ -z "\$CURRENT_KUBE_VERSION" ] || [ "\$CURRENT_KUBE_VERSION" != "\$LATEST_KUBE_VERSION" ]; then
        echo -e "${YELLOW}    Устанавливаем kubectl v${LATEST_KUBE_VERSION}${NC}"
        curl -fsSL "https://dl.k8s.io/release/v${LATEST_KUBE_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
        sudo chmod +x /tmp/kubectl
        sudo mv /tmp/kubectl /usr/local/bin/
      fi

      echo -e "${GREEN}  Проверяем helm${NC}"
      CURRENT_HELM_VERSION="0.0.0"
      if command -v helm &>/dev/null; then
        CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      fi
      LATEST_HELM_VERSION=\$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
      if [ -z "\$CURRENT_HELM_VERSION" ] || [ "\$CURRENT_HELM_VERSION" != "\$LATEST_HELM_VERSION" ]; then
        echo -e "${YELLOW}    Устанавливаем helm v${LATEST_HELM_VERSION}${NC}"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
      fi
    fi

    apt-get --with-new-pkgs upgrade -y >/dev/null
    apt-get autoremove -y >/dev/null
EOF
done

echo -e "${GREEN}Подготовительные работы завершены (рекомендуется выполнить резервное копирование)${NC}"
echo -e "${GREEN}${NC}"

# echo -e "${GREEN}  Отправляем настройки на серверы${NC}"
# for node in "${!NODES[@]}"; do
#   ip="${NODES[$node]}"
#   if [[ $node == s* ]]; then
#     if [[ $node == s1 ]]; then
#       scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/.kube/rke2m_cilium_config.yaml" "$USER@${NODES[s1]}:$HOME/rke2_cilium_config.yaml" >/dev/null
#     else
#       scp -i "$HOME/.ssh/$CERT_NAME" "$HOME/.kube/rke2_config.yaml" "$USER@$ip:$HOME/rke2_config.yaml" >/dev/null
#     fi
#   fi
# done
