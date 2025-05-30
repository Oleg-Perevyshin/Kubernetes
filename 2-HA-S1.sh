#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 2-HA-S1.sh;

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [vip]="192.168.5.20"
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
  [backup]="192.168.5.17"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}" "${NODES[backup]}")

# Виртуальный IP адрес
VIP_INTERFACE="ens18"

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
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

echo -e "${GREEN}ЭТАП 2: Подготовка узлов кластера и настройка первого сервера RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность всех узлов${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c 1 -W 1 "${node_ip}" >/dev/null || {
    echo -e "${RED}    ✗ Узел ${node_ip} недоступен, установка прервана${NC}"
    exit 1
  }
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем сертификат${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден${NC}"
  exit 1
fi
# ----------------------------------------------------------------------------------------------- #
for node_ip in "${ORDERED_NODES[@]}"; do
  for name in "${!NODES[@]}"; do
    if [[ "${NODES[$name]}" == "${node_ip}" ]]; then
      node_name="${name}"
      break
    fi
  done
  if [[ -z "$node_name" ]]; then
    echo -e "${RED}  Не найдено имя для IP ${node_ip}, установка прервана${NC}"
    exit 1
  fi
  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Подготавливаем узел ${node_ip}${NC}"
  ssh -q -i "/root/.ssh/$CERT_NAME" "root@${node_ip}" bash <<PRE_CONFIG_NODES
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export PATH=$PATH:/usr/local/bin

    echo -e "${GREEN}  Обновляем систему${NC}"
    apt-get update  &>/dev/null
    apt-get upgrade -y &>/dev/null

    echo -e "${GREEN}  Отключаем фаервол, раздел SWAP (для узлов кластера), оптимизируем загрузку...${NC}"
    systemctl disable --now ufw &>/dev/null || true
    if [[ "${node_name}" != "backup" ]]; then
      sed -i '/[[:space:]]*swap/s/^\([^#]\)/# \1/' /etc/fstab
      swapoff -a
    fi
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub

    if [[ "${node_name}" == "backup" ]]; then
      echo -e "${GREEN}  Настраиваем узел Backup${NC}"
      apt-get install nano mc nfs-kernel-server systemd-timesyncd -y &>/dev/null
      systemctl enable --now systemd-timesyncd && timedatectl set-ntp off && timedatectl set-ntp on
      mkdir -p /mnt/longhorn_backups &>/dev/null
      chown nobody:nogroup /mnt/longhorn_backups &>/dev/null
      chmod 777 /mnt/longhorn_backups &>/dev/null
      sed -i '\#/mnt/longhorn_backups#d' /etc/exports && \
        echo '/mnt/longhorn_backups 192.168.5.0/24(rw,sync,no_subtree_check,no_root_squash)' | sudo tee -a /etc/exports >/dev/null
      exportfs -a >/dev/null
      systemctl restart nfs-kernel-server >/dev/null
    fi

    if [[ "${node_name}" != "backup" ]]; then
      echo -e "${GREEN}  Устанавливаем базовые пакеты и синхронизируем время...${NC}"
      apt-get install nano mc git curl jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y &>/dev/null
      systemctl enable --now systemd-timesyncd && timedatectl set-ntp off && timedatectl set-ntp on
    fi

    if [[ "${node_name}" == "s1" ]]; then
      echo -e "${GREEN}  Устанавливаем Docker на первый сервер${NC}"
      curl -fsSL -A "Mozilla/5.0" https://get.docker.com | sh &>/dev/null
      systemctl enable docker.service containerd.service &>/dev/null
    fi

    if [[ "${node_name}" == s* ]]; then
      echo -e "${GREEN}  Устанавливаем дополнительные пакеты на сервер${NC}"
      CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      LATEST_HELM_VERSION=\$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
      if [ "$(printf '%s\n' "\$LATEST_HELM_VERSION" "\$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "\$LATEST_HELM_VERSION" ]; then
        curl -fsSL -A "Mozilla/5.0" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>/dev/null
      fi
      if ! helm version --client &>/dev/null; then
        echo -e "${RED}    ✗ Ошибка: HELM не установлен корректно${NC}"
        exit 1
      fi
      CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      echo -e "${GREEN}    ✓ HELM установлен, версия \$CURRENT_HELM_VERSION${NC}"
    fi

    echo 'export PATH=$PATH:/usr/local/bin' >> /root/.bashrc
    echo 'source /root/.bashrc' >> /root/.profile
    source /root/.bashrc

    echo -e "${GREEN}  Очищаем систему${NC}"
    apt-get autoremove -y >/dev/null
    apt-get upgrade -y &>/dev/null
    echo -e "${GREEN}  Узел подготовлен${NC}"
PRE_CONFIG_NODES
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  echo -e "${GREEN}  Перезагружаем узел ${node_ip}${NC}"
  ssh -q -o "LogLevel=ERROR" -i "/root/.ssh/$CERT_NAME" "root@${node_ip}" "reboot" </dev/null &>/dev/null &
  sleep 1
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}  Ждем запуск всех узлов...${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  for i in {1..60}; do
    if ping -c 1 -W 1 "${node_ip}" &>/dev/null; then
      break
    fi
    if [ $i -eq 60 ]; then
      echo -e "${RED}      ✗ Узел ${node_ip} недоступен, установка прервана${NC}"
      exit 1
    fi
    sleep 1
  done
done
echo -e "${GREEN}    ✓ Все узлы запущены${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" bash <<MAIN_SERVER
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  echo -e "${GREEN}  Устанавливаем и запускаем RKE2 на первом сервере, ждите...${NC}"
  mkdir -p "/var/lib/rancher/rke2/server/manifests/" >/dev/null
  install -D -m 600 /dev/null "/etc/rancher/rke2/config.yaml" && cat > "/etc/rancher/rke2/config.yaml" <<CONFIG_SERVER
node-ip: "${NODES[s1]}"
tls-san: [${NODES[vip]}, ${NODES[s1]}, ${NODES[s2]}, ${NODES[s3]}]
write-kubeconfig-mode: 600
etcd-expose-metrics: true
CONFIG_SERVER

  tar xzf /root/rke2.linux-amd64.tar.gz -C /usr/local
  ln -sf /usr/local/bin/rke2 /usr/local/bin/rke2-server
  cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now rke2-server.service
  for count in {1..30}; do
    if [ -f /etc/rancher/rke2/rke2.yaml ]; then
      break
    elif [ "\$count" -eq 30 ]; then
      echo -e "${RED}    ✗ Файл конфигурации не создан, установка прервана${NC}"
      exit 1
    else
      sleep 10
    fi
  done
  rm -f "/root/rke2.linux-amd64.tar.gz"

  echo -e "${GREEN}  Настраиваем окружение${NC}"
  grep -q "export KUBECONFIG=" "/root/.bashrc" ||echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> "/root/.bashrc"
  grep -q "export PATH=.*rancher/rke2/bin" "/root/.bashrc" || echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' >> "/root/.bashrc"
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

  kubectl delete daemonset kube-vip-ds -n kube-system --ignore-not-found >/dev/null
  kubectl apply -f https://kube-vip.io/manifests/rbac.yaml >/dev/null
  VIP_VERSION=\$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")
  docker run --network host --rm ghcr.io/kube-vip/kube-vip:\${VIP_VERSION} \
    manifest daemonset \
      --interface ${VIP_INTERFACE} \
      --address ${NODES[vip]} \
      --inCluster \
      --controlplane \
      --services \
      --arp \
      --leaderElection 2>/dev/null | kubectl apply -f - >/dev/null
MAIN_SERVER
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}  Копируем конфигурацию кластера на текущую машину${NC}"
mkdir -p "/root/.kube" >/dev/null || true
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" "cat /var/lib/rancher/rke2/server/token" > "/root/.kube/${PREFIX_CONFIG}_Cluster_Token"
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" "cat /etc/rancher/rke2/rke2.yaml" > "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
sed -i \
  -e "s/127.0.0.1/${NODES[vip]}/g" \
  -e "0,/name: default/s//name: RKE2-HA-${PREFIX_CONFIG}Cluster/" \
  -e "s/cluster: default/cluster: RKE2-HA-${PREFIX_CONFIG}Cluster/" \
  "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
chown "$(id -u):$(id -g)" "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
export KUBECONFIG=/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Ожидаем готовности сервера${NC}"
for i in {1..60}; do
  if curl -sk https://${NODES[vip]}:6443/livez &>/dev/null; then
    break
  else
    echo -e "${YELLOW}  Сервер еще не готов, ждите...${NC}"
  fi

  if [ $i -eq 60 ]; then
    echo -e "${RED}  Сервер не запустился, установка прервана${NC}"
    exit 1
  fi

  sleep 10
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Первый сервер запущен${NC}"
echo -e "${GREEN}${NC}"
