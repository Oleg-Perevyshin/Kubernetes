#!/bin/bash

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

# Все серверы без первого
SERVERS_WITHOUT_FIRST=("s2" "s3")

# Имя пользователя, имя файла SSH сертификата и набор адресов
USER="poe"
CERT_NAME="id_rsa_master"
PASSWORD="MCMega2005!"
PREFIX_CONFIG="Home"

# Виртуальный IP адрес (VIP)
VIP="192.168.5.20"
VIP_INTERFACE="ens18"

# Диапазон адресов для Loadbalancer - это установлено на /27 в rke2-cilium-config.yaml (32-63)
LB_RANGE="192.168.5.32/27"

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
echo -e "${GREEN}ЭТАП 2: Настройка остальных серверов${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Получаем токен доступа${NC}"
TOKEN=$(<"$HOME/.kube/${PREFIX_CONFIG}_Cluster_Token")

for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  if [[ $node == s* && $node != s1 ]]; then
    # shellcheck disable=SC2087
    ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$ip" sudo bash -c "bash -s" <<EOF
      echo -e "${GREEN}${NC}"
      echo -e "${GREEN}  Настраиваем сервер $ip${NC}"
      set -euo pipefail
      if ip addr show | grep -q "$VIP"; then
        echo -e "${RED}  ✗ Ошибка: VIP $VIP уже используется${NC}"
        exit 1
      fi
      if ! sudo -n true 2>/dev/null; then
        echo -e "${RED}  ✗ Ошибка: пользователь $USER не может выполнять sudo без пароля${NC}"
        exit 1
      fi
      sudo mkdir -p "/etc/rancher/rke2" >/dev/null
      echo -e "${GREEN}  Создаем конфигурацию RKE2${NC}"
      cat <<EOL | sudo tee "/etc/rancher/rke2/config.yaml" >/dev/null
token: $TOKEN
server: https://${NODES[s1]}:9345
tls-san:
  - ${VIP}
  - ${NODES[s1]}
  - ${NODES[s2]}
  - ${NODES[s3]}
system-default-registry: "docker.io"
EOL

      echo -e "${GREEN}  Создаем конфигурацию VIP${NC}"
      sudo mkdir -p /var/lib/rancher/rke2/server/manifests >/dev/null
      KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name" | sed 's/^v//')
      cat <<EOL | sudo tee "/var/lib/rancher/rke2/server/manifests/kube-vip.yaml" >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata:
  creationTimestamp: null
  name: kube-vip-ds
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: kube-vip-ds
  template:
    metadata:
      creationTimestamp: null
      labels:
        name: kube-vip-ds
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: Exists
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
      containers:
      - args:
        - manager
        env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: $VIP_INTERFACE
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: vip_ddns
          value: "false"
        - name: svc_enable
          value: "true"
        - name: svc_leasename
          value: plndr-svcs-lock
        - name: vip_leaderelection
          value: "true"
        - name: vip_leasename
          value: plndr-cp-lock
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: $VIP
        - name: prometheus_server
          value: :2112
        image: ghcr.io/kube-vip/kube-vip:v\$KVVERSION
        imagePullPolicy: Always
        name: kube-vip
        resources: {}
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
            - SYS_TIME
      hostNetwork: true
      serviceAccountName: kube-vip
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
  updateStrategy: {}
status:
  currentNumberScheduled: 0
  desiredNumberScheduled: 0
  numberMisscheduled: 0
  numberReady: 0
EOL

      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh - >/dev/null
      systemctl enable rke2-server.service >/dev/null
      systemctl start rke2-server.service >/dev/null
      until [ -f /etc/rancher/rke2/rke2.yaml ]; do sleep 10; done

      echo -e "${GREEN}  Настраиваем окружение${NC}"
      if ! grep -q "export KUBECONFIG=" "/home/$USER/.bashrc"; then
        echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | sudo tee -a "/home/$USER/.bashrc" >/dev/null
      fi
      if ! grep -q "export PATH=.*rancher/rke2/bin" "/home/$USER/.bashrc"; then
        echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' | sudo tee -a "/home/$USER/.bashrc" >/dev/null
      fi
      if ! grep -q "alias k=" "/home/$USER/.bashrc"; then
        echo 'alias k=kubectl' | sudo tee -a "/home/$USER/.bashrc" >/dev/null
      fi
      sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
      source "/home/$USER/.bashrc" >/dev/null
      exit
EOF
  fi
done

echo -e "${GREEN}Все серверы настроены${NC}"
echo -e "${GREEN}${NC}"
