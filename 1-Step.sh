#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 1-Step.sh;

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

# Виртуальный IP адрес
VIP_INTERFACE="ens18"
VIP_ADDRESS="192.168.5.20"
LB_RANGE="192.168.5.21-192.168.5.29"
VIP_VERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

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

echo -e "${GREEN}ЭТАП 1: Подготовка узлов кластера и настройка первого сервера RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность всех узлов${NC}"
for node in "${NODES[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}    ✗ Узел $node недоступен, установка прервана${NC}"
    exit 1
  }
done

echo -e "${GREEN}  Проверяем сертификат${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден${NC}"
  exit 1
fi

for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Подготавливаем узел $ip${NC}"
  ssh -q -i "/root/.ssh/$CERT_NAME" "root@$ip" bash <<EOF
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export PATH=$PATH:/usr/local/bin

    echo -e "${GREEN}  Обновляем систему...${NC}"
    apt-get update  &>/dev/null
    apt-get upgrade -y &>/dev/null

    echo -e "${GREEN}  Отключаем фаервол, отключаем раздел SWAP и оптимизируем загрузку...${NC}"
    systemctl disable --now ufw 2>/dev/null || true
    sed -i '/[[:space:]]*swap/s/^\([^#]\)/# \1/' /etc/fstab
    swapoff -a
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub

    echo -e "${GREEN}  Устанавливаем базовые пакеты и синхронизируем время...${NC}"
    apt-get install nano mc git curl jq systemd-timesyncd iptables nfs-common open-iscsi ipset conntrack -y &>/dev/null
    systemctl enable --now systemd-timesyncd && timedatectl set-ntp off && timedatectl set-ntp on

    if [[ "$node" == "s1" ]]; then
      echo -e "${GREEN}  Устанавливаем Docker на первый сервер...${NC}"
      curl -fsSL -A "Mozilla/5.0" https://get.docker.com | sh &>/dev/null
      systemctl enable docker.service containerd.service &>/dev/null
    fi

    if [[ $node == s* ]]; then
      echo -e "${GREEN}  Устанавливаем дополнительные пакеты на сервер...${NC}"
      CURRENT_KUBE_VERSION=\$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print \$3}' | sed 's/^v//' || echo "0.0.0")
      LATEST_KUBE_VERSION=\$(curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//' || echo "0.0.0")
      if [ "$(printf '%s\n' "\$LATEST_KUBE_VERSION" "\$CURRENT_KUBE_VERSION" | sort -V | head -n1)" != "\$LATEST_KUBE_VERSION" ]; then
        curl -fsSL -A "Mozilla/5.0" "https://dl.k8s.io/release/v\${LATEST_KUBE_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
        chmod +x /usr/local/bin/kubectl
      fi
      if ! kubectl version --client &>/dev/null; then
        echo -e "${RED}    ✗ Ошибка: KUBECTL не установлен корректно${NC}"
        exit 1
      fi
      CURRENT_KUBE_VERSION=\$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print \$3}' | sed 's/^v//' || echo "0.0.0")
      echo -e "${GREEN}    ✓ KUBECTL установлен, версия \$CURRENT_KUBE_VERSION${NC}"

      CURRENT_HELM_VERSION=\$(helm version --client 2>/dev/null | awk -F'"' '/Version:/{print \$2}' | sed 's/^v//' || echo "0.0.0")
      LATEST_HELM_VERSION=\$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name' | sed 's/^v//')
      if [ "$(printf '%s\n' "\$LATEST_HELM_VERSION" "\$CURRENT_HELM_VERSION" | sort -V | head -n1)" != "\$LATEST_HELM_VERSION" ]; then
        curl -fsSL -A "Mozilla/5.0" https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
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

    echo -e "${GREEN}  Очистка системы...${NC}"
    apt-get autoremove -y >/dev/null
    apt-get upgrade -y &>/dev/null
    echo -e "${GREEN}  ✓ Узел подготовлен${NC}"
EOF
done

echo -e "${GREEN}${NC}"
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  echo -e "${GREEN}  Инициируем перезагрузку узла $ip${NC}"
  ssh -i "/root/.ssh/$CERT_NAME" "root@$ip" "reboot &>/dev/null & exit"
  sleep 1
done

echo -e "${GREEN}${NC}"
echo -e "${GREEN}  Ждем запуск всех узлов...${NC}"
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  for i in {1..60}; do
    if ping -c 1 -W 1 "$ip" &>/dev/null; then
      echo -e "${GREEN}    ✓ Узел $ip готов к работе${NC}"
      break
    fi
    if [ $i -eq 60 ]; then
      echo -e "${RED}      ✗ Узел $ip недоступен, установка прервана${NC}"
      exit 1
    fi
    sleep 1
  done
done

echo -e "${GREEN}${NC}"
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" bash <<EOF
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  mkdir -p "/etc/rancher/rke2/" >/dev/null
  mkdir -p "/var/lib/rancher/rke2/server/manifests/" >/dev/null
  echo -e "${GREEN}  Создаем конфигурацию RKE2${NC}"
  cat <<EOL | tee "/etc/rancher/rke2/config.yaml" >/dev/null
tls-san:
  - ${VIP_ADDRESS}
  - ${NODES[s1]}
  - ${NODES[s2]}
  - ${NODES[s3]}
EOL

  echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh -s - >/dev/null || {
    echo -e "${RED}    ✗ Ошибка при установке RKE2, установка прервана${NC}"
    exit 1
  }
  systemctl enable rke2-server.service
  systemctl start rke2-server.service
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

  echo -e "${GREEN}  Настраиваем окружение${NC}"
  if ! grep -q "export KUBECONFIG=" "/root/.bashrc"; then
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | tee -a "/root/.bashrc" >/dev/null
  fi
  if ! grep -q "export PATH=.*rancher/rke2/bin" "/root/.bashrc"; then
    echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' | tee -a "/root/.bashrc" >/dev/null
  fi
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

  # kubectl delete daemonset kube-vip-ds -n kube-system --ignore-not-found
  # kubectl apply -f https://kube-vip.io/manifests/rbac.yaml >/dev/null
  # docker run --network host --rm ghcr.io/kube-vip/kube-vip:$VIP_VERSION \
  # manifest daemonset \
  #   --interface $VIP_INTERFACE \
  #   --address $VIP_ADDRESS \
  #   --inCluster \
  #   --controlplane \
  #   --services \
  #   --arp \
  #   --leaderElection \
  # | kubectl apply -f - >/dev/null

  # kubectl rollout status daemonset kube-vip-ds -n kube-system --timeout=120s
EOF
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}  Ожидаем запуск RKE2 сервера, это может занять 2-3 минуты${NC}"
for attempt in {1..30}; do
  if ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" \
      "export PATH=\$PATH:/var/lib/rancher/rke2/bin; kubectl get nodes --request-timeout=5s 2>/dev/null"; then
    echo -e "${GREEN}    ✓ Кластер успешно запущен${NC}"
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo -e "${RED}    ✗ Превышено время ожидания запуска кластера, установка прервана${NC}"
    exit 1
  fi

  echo -e "${YELLOW}    Ожидаем готовности кластера...${NC}"
  sleep 10
done

echo -e "${GREEN}  Копируем конфигурацию кластера на текущую машину${NC}"
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" "cat /var/lib/rancher/rke2/server/node-token" > "/root/.kube/${PREFIX_CONFIG}_Cluster_Token"
ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" "cat /etc/rancher/rke2/rke2.yaml" > "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
# -e "s/127.0.0.1/$VIP_ADDRESS/g" \
sed -i \
  -e "s/127.0.0.1/${NODES[s1]}/g" \
  -e "0,/name: default/s//name: RKE2-HA-${PREFIX_CONFIG}Cluster/" \
  -e "s/cluster: default/cluster: RKE2-HA-${PREFIX_CONFIG}Cluster/" \
  "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
chown "$(id -u):$(id -g)" "/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml"
export KUBECONFIG=/root/.kube/${PREFIX_CONFIG}_Cluster_Config.yaml
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}Узлы кластера предварительно настроены и первый сервер успешно запущен${NC}"
echo -e "${GREEN}${NC}"
