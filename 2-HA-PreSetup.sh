#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 2-HA-PreSetup.sh;

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.31" [s2]="192.168.5.32" [s3]="192.168.5.33"
  [a1]="192.168.5.34" [a2]="192.168.5.35" [a3]="192.168.5.36"
  [bu]="192.168.5.39"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}" "${NODES[bu]}")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 2: Предварительная подготовка узлов кластера${NC}"
# ----------------------------------------------------------------------------------------------- #
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done
[ ! -f "$CLUSTER_SSH_KEY" ] && echo -e "${RED}  ✗ SSH ключ $CLUSTER_SSH_KEY не найден, установка прервана${NC}" && exit 1

for node_ip in "${ORDERED_NODES[@]}"; do
  node_name=""
  for name in "${!NODES[@]}"; do
    [[ "${NODES[$name]}" == "$node_ip" ]] && node_name="$name" && break
  done
  [[ -z "$node_name" ]] && { echo -e "${RED}  ✗ Не найдено имя для IP ${node_ip}, установка прервана${NC}"; exit 1; }

  echo -e "${GREEN}  Подготавливаем узел ${node_ip}${NC}";
  ssh -q -i "$CLUSTER_SSH_KEY" "root@${node_ip}" bash <<PRE_SETUP
    set -euo pipefail
    export PATH=\$PATH:/usr/local/bin

    apt-get update -y &>/dev/null
    apt-get upgrade -y &>/dev/null

    if [[ "$node_name" == "bu" ]]; then
      echo -e "${GREEN}    Настраиваем Backup-узел${NC}"
      apt-get install nano mc nfs-kernel-server systemd-timesyncd -y &>/dev/null
      systemctl enable --now systemd-timesyncd
      timedatectl set-ntp off && timedatectl set-ntp on
      mkdir -p /mnt/longhorn_backups
      chown nobody:nogroup /mnt/longhorn_backups
      chmod 777 /mnt/longhorn_backups
      sed -i '\#/mnt/longhorn_backups#d' /etc/exports
      echo '/mnt/longhorn_backups 192.168.5.0/24(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports
      exportfs -a
      systemctl restart nfs-kernel-server
    else
      echo -e "${GREEN}    Устанавливаем базовые пакеты${NC}"
      apt-get install nano mc git curl jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y &>/dev/null
      systemctl enable --now systemd-timesyncd
      timedatectl set-ntp off && timedatectl set-ntp on
    fi

    if [[ "$node_name" == "s1" ]]; then
      echo -e "${GREEN}    Устанавливаем Docker${NC}"
      curl -fsSL https://get.docker.com | sh &>/dev/null
      systemctl enable docker.service containerd.service
    fi

    if [[ "${node_name}" == s* ]]; then
      echo -e "${GREEN}    Устанавливаем Helm${NC}"
      CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      LATEST_HELM_VERSION=\$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
      if [ "$(printf '%s\n' "\$LATEST_HELM_VERSION" "\$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "\$LATEST_HELM_VERSION" ]; then
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>/dev/null
      fi
      helm version --client &>/dev/null || { echo -e "${RED}    ✗ HELM не установлен, установка прервана${NC}"; exit 1; }
      CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      echo -e "${GREEN}    ✓ HELM установлен, версия \$CURRENT_HELM_VERSION${NC}"
    fi

    echo 'export PATH=\$PATH:/usr/local/bin' >> /root/.bashrc
    echo 'source /root/.bashrc' >> /root/.profile

    apt-get autoremove -y &>/dev/null
    apt-get upgrade -y &>/dev/null
    echo -e "${GREEN}  Узел подготовлен${NC}"
PRE_SETUP
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  echo -e "${GREEN}  Перезагружаем узел ${node_ip}${NC}"
  ssh -q -o "LogLevel=ERROR" -i "$CLUSTER_SSH_KEY" "root@${node_ip}" "reboot" </dev/null &>/dev/null &
  sleep 1
done

echo -e "${GREEN}${NC}"; echo -e "${GREEN}  Ожидаем запуск всех узлов...${NC}";
for node_ip in "${ORDERED_NODES[@]}"; do
  for i in {1..60}; do
    ping -c 1 -W 1 "$node_ip" &>/dev/null && break
    [ "$i" -eq 60 ] && { echo -e "${RED}    ✗ Узел $node_ip не запустился, установка прервана${NC}"; exit 1; }
    sleep 1
  done
done
echo -e "${GREEN}Все узлы кластера подготовлены${NC}"; echo -e "${GREEN}${NC}"
