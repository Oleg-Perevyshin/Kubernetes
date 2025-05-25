#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 3-Step.sh;

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

echo -e "${GREEN}ЭТАП 3: Подготовка агентов RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность агентов${NC}"
for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  if [[ $node == a* ]]; then
    ping -c 1 -W 1 "$ip" >/dev/null || {
      echo -e "${RED}    ✗ Агент $ip недоступен, установка прервана${NC}"
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
  if [[ $node == a* ]]; then
    ssh -i "/root/.ssh/$CERT_NAME" "root@$ip" bash -c "bash -s" <<EOF
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export PATH=$PATH:/usr/local/bin

      echo -e "${GREEN}${NC}"
      echo -e "${GREEN}  Настраиваем агент $ip${NC}"
      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      mkdir -p "/etc/rancher/rke2/"
      cat <<EOL | tee "/etc/rancher/rke2/config.yaml" >/dev/null
token: $TOKEN
# server: https://${VIP_ADDRESS}:9345
server: https://${NODES[s1]}:9345
node-label:
  - worker=true
  - longhorn=true
EOL

      curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -s - >/dev/null || {
        echo -e "${RED}    ✗ Ошибка при установке RKE2, установка прервана${NC}"
        exit 1
      }
      systemctl enable rke2-agent.service
      systemctl start rke2-agent.service
      for count in {1..30}; do
        if systemctl is-active --quiet rke2-agent.service; then
          break
        elif [ "\$count" -eq 30 ]; then
          echo -e "${RED}    ✗ Агент не запустился, установка прервана${NC}"
          exit 1
        else
          sleep 10
        fi
      done

      echo -e "${GREEN}  ✓ Агент $ip присоединился к кластеру${NC}"
EOF
  fi
done
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Кластер RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
