#!/bin/bash
# Полная настройка мастер-машины кластера
# Сделать файл исполняемым на машине мастера chmod +x 0-Step.sh;

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

echo -e "${GREEN}ЭТАП 0: Подготовка мастер-узла${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Устанавливаем пакеты${NC}"
{
  apt-get update && apt-get upgrade -y
  systemctl disable --now ufw 2>/dev/null || true
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
echo -e "${GREEN}  Создаем папку для хранения настроек${NC}"
{
  rm -rf "/root/.kube"
  mkdir -p "/root/.kube"
  chmod 700 "/root/.kube"
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
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo -e "${GREEN}    ✓ HELM установлен, версия $LATEST_HELM_VERSION${NC}"
  else
    echo -e "${GREEN}    ✓ HELM установлен, версия $CURRENT_HELM_VERSION${NC}"
  fi
}
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Раздаем публичный ключ на все узлы${NC}"
for node in "${NODES[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}    ✗ Узел $node недоступен, установка прервана${NC}"
    exit 1
  }

  sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no "root@$node" \
    "echo '$(cat /root/.ssh/id_rsa_cluster.pub)' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>/dev/null

  if ! ssh -i "/root/.ssh/id_rsa_cluster" -o BatchMode=yes -o ConnectTimeout=5 "root@$node" exit >/dev/null 2>&1; then
    echo -e "${RED}    ✗ Ошибка проверки подключения к $node${NC}"
    exit 1
  fi
done
echo -e "${GREEN}    ✓ Ключ успешно передан${NC}"
# ----------------------------------------------------------------------------------------------- #
update-grub >/dev/null 2>&1
apt-get clean && apt-get autoremove -y >/dev/null

echo -e "${GREEN}Подготовительные работы завершены (рекомендуется выполнить резервное копирование)${NC}"
echo -e "${GREEN}${NC}"
