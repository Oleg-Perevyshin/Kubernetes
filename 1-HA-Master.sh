#!/bin/bash
# Полная настройка мастер-машины кластера
# Сделать файл исполняемым на машине мастера chmod +x 1-HA-Master.sh;
# export KUBECONFIG=/root/.kube/Home_Cluster_Config.yaml

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
  [backup]="192.168.5.17"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}" "${NODES[backup]}")

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
PASSWORD="MCMega2005!"
PREFIX_CONFIG="Home"

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}ЭТАП 1: Подготовка мастер-узла${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Создаем папку для хранения настроек${NC}"
mkdir -p "/root/.kube" 2>/dev/null || true
chmod 700 "/root/.kube" 2>/dev/null || true
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Устанавливаем пакеты${NC}"
{
  apt-get update && apt-get upgrade -y
  systemctl disable --now ufw &>/dev/null || true
  apt-get install nano mc curl sshpass jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y
  systemctl enable --now systemd-timesyncd && timedatectl set-ntp off && timedatectl set-ntp on
  sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
} >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Генерируем ключи для мастер-машины кластера${NC}"
{
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  # Если ключ уже существует - удаляем его и запись в authorized_keys
  if [ -f "/root/.ssh/${CERT_NAME}" ]; then
    OLD_PUB_KEY=$(cat "/root/.ssh/${CERT_NAME}.pub")
    if [ -f "/root/.ssh/authorized_keys" ]; then
      ESCAPED_KEY=$(echo "$OLD_PUB_KEY" | sed 's/[\/&]/\\&/g')
      sed -i "/${ESCAPED_KEY}/d" "/root/.ssh/authorized_keys"
    fi
    rm -f "/root/.ssh/${CERT_NAME}" "/root/.ssh/${CERT_NAME}.pub"
  fi
  ssh-keygen -t rsa -b 4096 -f "/root/.ssh/${CERT_NAME}" -C "cluster" -N ""
  cat "/root/.ssh/${CERT_NAME}.pub" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
} >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Создаем конфигурационный файл SSH клиента${NC}"
{
  SSH_CONFIG="/root/.ssh/config"
  [ -f "$SSH_CONFIG" ] || { touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"; }
  sed -i '/^Host \*/,/^$/d' "$SSH_CONFIG"
  echo -e "Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null" >> "$SSH_CONFIG"
  sed -i '/^$/N;/^\n$/D' "$SSH_CONFIG"
} >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем KUBECTL${NC}"
{
  CURRENT_KUBE_VERSION=$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}' | sed 's/^v//' || echo "0.0.0")
  LATEST_KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
  if [ "$(printf '%s\n' "$LATEST_KUBE_VERSION" "$CURRENT_KUBE_VERSION" | sort -V | head -n1)" != "$LATEST_KUBE_VERSION" ]; then
    curl -fsSL "https://dl.k8s.io/release/v${LATEST_KUBE_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
    chmod +x /usr/local/bin/kubectl
    echo -e "${GREEN}    ✓ KUBECTL установлен, версия $LATEST_KUBE_VERSION${NC}"
  else
    echo -e "${GREEN}    ✓ KUBECTL установлен, версия $CURRENT_KUBE_VERSION${NC}"
  fi
}

echo -e "${GREEN}  Проверяем HELM${NC}"
{
  CURRENT_HELM_VERSION=$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print $2}' | sed 's/^v//' || echo "0.0.0")
  LATEST_HELM_VERSION=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
  if [ "$(printf '%s\n' "$LATEST_HELM_VERSION" "$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "$LATEST_HELM_VERSION" ]; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>/dev/null
    echo -e "${GREEN}    ✓ HELM установлен, версия $LATEST_HELM_VERSION${NC}"
  else
    echo -e "${GREEN}    ✓ HELM установлен, версия $CURRENT_HELM_VERSION${NC}"
  fi
}
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Скачиваем RKE2${NC}"
{
  RKE2_VERSION=$(curl -s https://api.github.com/repos/rancher/rke2/releases/latest | grep tag_name | cut -d '"' -f 4)
  # RKE2_INSTALLER_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz"
  RKE2_INSTALLER_URL="https://github.com/rancher/rke2/releases/download/v1.32.5%2Brke2r1/rke2.linux-amd64.tar.gz"
  curl -fsSL -o "/root/rke2.linux-amd64.tar.gz" "$RKE2_INSTALLER_URL"
}
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Передаем публичный ключ и архив RKE2 на все узлы${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  for name in "${!NODES[@]}"; do
    if [[ "${NODES[$name]}" == "${node_ip}" ]]; then
      node_name="${name}"
      break
    fi
  done
  if [[ -z "${node_name}" ]]; then
    echo -e "${RED}  Не найдено имя для IP ${node_ip}, установка прервана${NC}"
    exit 1
  fi

  ping -c 1 -W 1 "${node_ip}" >/dev/null || {
    echo -e "${RED}    ✗ Узел ${node_ip} недоступен, установка прервана${NC}"
    exit 1
  }

  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "root@${node_ip}" \
    "echo '$(cat /root/.ssh/id_rsa_cluster.pub)' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null

  if ! ssh -i "/root/.ssh/id_rsa_cluster" -o BatchMode=yes -o ConnectTimeout=5 "root@${node_ip}" exit >/dev/null 2>&1; then
    echo -e "${RED}    ✗ Ошибка проверки SSH подключения к ${node_ip}${NC}"
    exit 1
  fi

  if [[ "${node_name}" != "backup" ]]; then
    scp -i "/root/.ssh/id_rsa_cluster" -o StrictHostKeyChecking=no "/root/rke2.linux-amd64.tar.gz" "root@${node_ip}:/root/rke2.linux-amd64.tar.gz" >/dev/null
  fi
done
echo -e "${GREEN}    ✓ Передача завершена${NC}"
rm -f "/root/rke2.linux-amd64.tar.gz"
# ----------------------------------------------------------------------------------------------- #
update-grub >/dev/null 2>&1
apt-get clean && apt-get autoremove -y >/dev/null
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Подготовительные работы завершены (рекомендуется выполнить резервное копирование)${NC}"
echo -e "${GREEN}${NC}"
