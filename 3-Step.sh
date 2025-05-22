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

# Имя пользователя, имя файла SSH сертификата и набор адресов
USER="poe"
CERT_NAME="id_rsa_master"
PREFIX_CONFIG="Home"

# Виртуальный IP адрес (VIP)
VIP="192.168.5.20"

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
echo -e "${GREEN}ЭТАП 3: Настройка агентов${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Получаем токен доступа${NC}"
TOKEN=$(<"$HOME/.kube/${PREFIX_CONFIG}_Cluster_Token")

for node in "${!NODES[@]}"; do
  ip="${NODES[$node]}"
  if [[ $node == a* ]]; then
    # shellcheck disable=SC2087
    ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@$ip" sudo bash -c "bash -s" <<EOF
      echo -e "${GREEN}${NC}"
      echo -e "${GREEN}  Работаем с агентом $ip${NC}"
      set -euo pipefail
      sudo mkdir -p /etc/rancher/rke2 >/dev/null
      echo -e "${GREEN}  Создаем конфигурацию RKE2${NC}"
      cat <<EOL | sudo tee "/etc/rancher/rke2/config.yaml" >/dev/null
token: $TOKEN
# server: https://${NODES[s1]}:9345
server: https://$VIP:9345
node-label:
  - worker=true
  - longhorn=true
EOL

      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - >/dev/null
      systemctl enable rke2-agent.service >/dev/null
      systemctl start rke2-agent.service >/dev/null
      exit
EOF
    echo -e "${GREEN}  Агент присоединился к кластеру${NC}"
  fi
done

echo -e "${GREEN}Все агенты настроены${NC}"
echo -e "${GREEN}${NC}"
