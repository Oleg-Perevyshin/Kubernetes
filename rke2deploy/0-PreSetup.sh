#!/bin/bash
# Вызвываем chmod +x 0-PreSetup.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Имя пользователя, пароль и сертификат доступа
USER="poe"
PASSWORD="MCMega2005!"
CERT_NAME="id_rsa_rke2m"

# Машины кластера
declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
# declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
ALL_CLUSTER_ITEMS=("${NODES[server]}" "${NODES[agent_1]}" "${NODES[agent_2]}")

####################################################################################################
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 0: Подготовка узлов${NC}"
#
#
echo -e "${GREEN}  Удаляем директорию .kube (если существует) и создаем новую${NC}"
if [ -d "$HOME/.kube" ]; then rm -rf "$HOME/.kube" || {
  echo -e "${RED}Ошибка удаления $HOME/.kube, установка прервана${NC}"
  exit 1
}; fi
mkdir -p "$HOME/.kube" || {
  echo -e "${RED}  Ошибка создания $HOME/.kube, установка прервана${NC}"
  exit 1
}
#
#
echo -e "${GREEN}  Проверяем доступность всех узлов кластера${NC}"
for node in "${ALL_CLUSTER_ITEMS[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}  Узел $node недоступен, установка прервана${NC}"
    exit 1
  }
done
#
#
echo -e "${GREEN}  Проверяем конфигурационный файл SSH${NC}"
SSH_CONFIG="$HOME/.ssh/config"
[ -f "$SSH_CONFIG" ] || { touch "$SSH_CONFIG" && chmod 600 "$SSH_CONFIG"; }
if ! grep -q "StrictHostKeyChecking" "$SSH_CONFIG"; then echo "StrictHostKeyChecking no" >>"$SSH_CONFIG"; fi
#
#
echo -e "${GREEN}  Проверяем kubectl${NC}"
if command -v kubectl &>/dev/null; then
  CURRENT_VERSION=$(kubectl version --client | grep 'Client Version' | awk '{print $3}' | sed 's/v//')
else
  CURRENT_VERSION=""
  echo -e "${YELLOW}  kubectl не установлен, выполняется установка${NC}"
fi
LATEST_VERSION=$(curl -L -s https://cdn.dl.k8s.io/release/stable.txt | sed 's/v//')
if [ -n "$CURRENT_VERSION" ]; then
  if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    sudo rm -f /usr/local/bin/kubectl
    curl -LO "https://dl.k8s.io/release/v$LATEST_VERSION/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  fi
else
  sudo rm -f /usr/local/bin/kubectl
  curl -LO "https://dl.k8s.io/release/v$LATEST_VERSION/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
fi
echo -e "${GREEN}  kubectl v$LATEST_VERSION установлен${NC}"
#
#
echo -e "${GREEN}  Добавляем SSH ключи ко всем узлам${NC}"
CERT_PATH="$HOME/.ssh/$CERT_NAME"
[ -f "$CERT_PATH" ] || {
  echo -e "${RED}  SSH-ключ не найден, установка прервана${NC}"
  exit 1
}
for host in "${NODES[@]}"; do
  sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$CERT_PATH" "$USER@$host" >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при передаче ключа на $host, пытаемся повторно${NC}"
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$host" # Удаляем старый ключ
    sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$CERT_PATH" "$USER@$host" >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка при повторной передаче ключа на $host, установка прервана${NC}"
      exit 1
    }
  }
done
#
#
# Подготавливаем все узлы
for newnode in "${ALL_CLUSTER_ITEMS[@]}"; do
  {
    echo -e "${GREEN}  Подготавливаем узел $newnode${NC}"
    # shellcheck disable=SC2087
    ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$newnode" sudo bash <<EOF
      set -e;
      if systemctl is-active --quiet ufw; then systemctl disable --now ufw; fi
      apt update -y > /dev/null 2>&1;
      echo -e "${GREEN}    Установка пакетов${NC}";
      apt install mc nano curl systemd-timesyncd iptables nfs-common open-iscsi -y > /dev/null 2>&1;
      systemctl start systemd-timesyncd && timedatectl set-ntp off && timedatectl set-ntp on && echo -e "${GREEN}    Синхронизация времени выполнена${NC}";
      apt upgrade -y > /dev/null 2>&1;
      apt autoremove -y > /dev/null 2>&1;
      poweroff;
EOF
    echo -e "${GREEN}  Узел подготовлен и выключается, сделайте Backup для отката!${NC}"
  } || {
    echo -e "${YELLOW}  Ошибка при подготовке узла $newnode, возможно, устройство выключено.${NC}"
  }
  echo -e "${GREEN}${NC}"
done
echo -e "${GREEN}Подготовительные работы завершены, запустите узлы кластера${NC}"
echo -e "${GREEN}${NC}"

# Сделать снимок состояния для отката!
