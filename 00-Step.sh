#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 00-Step.sh;

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

echo -e "${GREEN}Полный сброс кластера${NC}"
# ----------------------------------------------------------------------------------------------- #
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Обрабатываем узел $ip...${NC}"

  # Проверяем доступность узла
  if ! ping -c 1 -W 1 "$ip" &>/dev/null; then
    echo -e "${RED}    Узел $ip недоступен, пропускаем${NC}"
    continue
  fi

  # Определяем тип узла (control или worker)
  if [[ $node == s* ]]; then
    node_type="server"
  else
    node_type="agent"
  fi

  # Выполняем команды на удаленном узле через SSH
  echo -e "${GREEN}  Сбрасываем узел $ip...${NC}"
  ssh -i "/root/.ssh/$CERT_NAME" "root@$ip" bash <<EOF
    set -euo pipefail

    echo -e "${GREEN}  Остановка служб RKE2...${NC}"
    systemctl stop rke2-${node_type} &>/dev/null || true

    echo -e "${GREEN}  Удаление RKE2...${NC}"
    if [ -f /usr/local/bin/rke2-uninstall.sh ]; then
      /usr/local/bin/rke2-uninstall.sh &>/dev/null || true
    fi
    if [ -f /usr/local/bin/rke2-killall.sh ]; then
      /usr/local/bin/rke2-killall.sh &>/dev/null || true
    fi

    echo -e "${GREEN}  Очистка сетевых интерфейсов...${NC}"
    ip link delete cilium_host &>/dev/null || true
    ip link delete cilium_net &>/dev/null || true
    ip link delete cilium_vxlan &>/dev/null || true

    echo -e "${GREEN}  Очистка каталогов...${NC}"
    rm -rf /var/lib/cni/ &>/dev/null
    rm -rf /var/lib/kubelet/ &>/dev/null
    rm -rf /var/lib/rancher/ &>/dev/null
    rm -rf /var/lib/calico/ &>/dev/null
    rm -rf /etc/cni/ &>/dev/null
    rm -rf /etc/rancher/ &>/dev/null

    echo -e "${GREEN}  Удаление системных файлов...${NC}"
    rm -f /etc/systemd/system/rke2*.service &>/dev/null
    rm -rf /var/lib/rancher/rke2/ &>/dev/null
    rm -f /usr/local/bin/rke2 &>/dev/null
    rm -f /usr/local/bin/kubectl &>/dev/null
    rm -f /usr/local/bin/crictl &>/dev/null

    echo -e "${GREEN}  Сброс iptables...${NC}"
    iptables -F &>/dev/null
    iptables -t nat -F &>/dev/null
    ipset destroy || true &>/dev/null

    if [ "$node" == "s1" ] && [ -x "$(command -v docker)" ]; then
      echo -e "${GREEN}  Очистка Docker...${NC}"
      systemctl restart docker &>/dev/null || true
      docker system prune -a -f &>/dev/null || true
    fi

    if [[ "$node_type" == "server" ]]; then
      echo -e "${GREEN}  Удаление данных etcd...${NC}"
      rm -rf /var/lib/rancher/rke2/server/db/ &>/dev/null

      echo -e "${GREEN}  Удаление HELM...${NC}"
      rm -f /usr/local/bin/helm
      rm -rf /root/.helm /root/.config/helm /root/.cache/helm /root/.local/share/helm
      rm -f /etc/bash_completion.d/helm &>/dev/null || true
    fi
EOF

  # Перезагружаем узел
  ssh -i "/root/.ssh/$CERT_NAME" "root@$ip" "nohup reboot &>/dev/null & exit" || true
  echo -e "${GREEN}  Узел $ip отправлен на перезагрузку${NC}"

done

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Сброс кластера завершен${NC}"
echo -e "${GREEN}${NC}"
