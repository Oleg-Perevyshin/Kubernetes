#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 2-Step.sh;

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
#VIP_VERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

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

echo -e "${GREEN}ЭТАП 2: Подготовка остальных серверов RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность серверов${NC}"
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  if [[ $node == s* ]]; then
    ping -c 1 -W 1 "$ip" >/dev/null || {
      echo -e "${RED}    ✗ Сервер $ip недоступен, установка прервана${NC}"
      exit 1
    }
  fi
done

echo -e "${GREEN}  Проверяем сертификат${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден${NC}"
  exit 1
fi

echo -e "${GREEN}  Получаем токен доступа${NC}"
TOKEN=$(cat "/root/.kube/${PREFIX_CONFIG}_Cluster_Token")

for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  if [[ $node == s* && $node != s1 ]]; then
    ssh -i "/root/.ssh/$CERT_NAME" "root@$ip" bash -c "bash -s" <<EOF
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export PATH=$PATH:/usr/local/bin

      echo -e "${GREEN}${NC}"
      echo -e "${GREEN}  Настраиваем сервер $ip${NC}"
      mkdir -p "/etc/rancher/rke2" >/dev/null
      mkdir -p "/var/lib/rancher/rke2/server/manifests/" >/dev/null
      echo -e "${GREEN}  Создаем конфигурацию RKE2${NC}"
      cat <<EOL | tee "/etc/rancher/rke2/config.yaml" >/dev/null
# server: https://${VIP_ADDRESS}:9345
server: https://${NODES[s1]}:9345
token: $TOKEN
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

#       cat <<EOL | tee "/var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml" >/dev/null
# ---
# apiVersion: helm.cattle.io/v1
# kind: HelmChartConfig
# metadata:
#   name: rke2-ingress-nginx
#   namespace: kube-system
# spec:
#   valuesContent: |-
#     controller:
#       metrics:
#         service:
#           annotations:
#             prometheus.io/scrape: "true"
#             prometheus.io/port: "10254"
#       config:
#         use-forwarded-headers: "true"
#       allowSnippetAnnotations: "true"
# EOL

      echo -e "${GREEN}  Настраиваем окружение${NC}"
      if ! grep -q "export KUBECONFIG=" "/root/.bashrc"; then
        echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' | tee -a "/root/.bashrc" >/dev/null
      fi
      if ! grep -q "export PATH=.*rancher/rke2/bin" "/root/.bashrc"; then
        echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' | tee -a "/root/.bashrc" >/dev/null
      fi
      ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
EOF
  fi
done
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}Все серверы успешно настроены, перезагрузите узлы${NC}"
echo -e "${GREEN}${NC}"
