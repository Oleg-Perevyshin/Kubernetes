#!/bin/bash
# Вызвываем chmod +x 5-NeuVector.sh; из командной строки чтоб сделать файл исполняемым

# Прекращение выполнения при любой ошибке
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"
PREFIX_CONFIG="office"
NEUVECTOR_HOST="neuvector.${PREFIX_CONFIG}.local"

# Машины кластера
if [[ "$PREFIX_CONFIG" == "home" ]]; then
  declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
elif [[ "$PREFIX_CONFIG" == "office" ]]; then
  declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
else
  echo -e "${RED}Неизвестный кластер $PREFIX_CONFIG, установка прервана${NC}"
  exit 1
fi

####################################################################################################
echo -e "${GREEN}ЭТАП 5: Установка NeuVector${NC}"
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -e;
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  #
  #
  echo -e "${GREEN}  Проверяем установку kubectl и Helm${NC}";
  if ! command -v kubectl &> /dev/null; then echo -e "${RED}kubectl не установлен, установка прервана${NC}"; exit 1; fi
  if ! command -v helm &> /dev/null; then echo -e "${RED}helm не установлен, установка прервана${NC}"; exit 1; fi
  #
  #
  echo -e "${GREEN}  Добавляем репозитории NeuVector${NC}";
  helm repo add neuvector https://neuvector.github.io/neuvector-helm/ --force-update >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка при добавлении репозитория NeuVector${NC}"; exit 1;
  }
  helm repo update >/dev/null 2>&1;
  #
  #
  echo -e "${GREEN}  Устанавливаем NeuVector${NC}";
  helm upgrade -i neuvector \
    --create-namespace --namespace cattle-neuvector-system neuvector/core \
    --set manager.svc.type=ClusterIP \
    --set controller.pvc.enabled=true \
    --set controller.pvc.capacity=500Mi \
    --set manager.ingress.enabled=true \
    --set manager.ingress.host="${NEUVECTOR_HOST}" \
    --set manager.ingress.tls=true \
    --wait --timeout 180m || {
    echo -e "${RED}  Ошибка при установке NeuVector${NC}"; exit 1;
  }
EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}NeuVector установлен${NC}"
echo -e "${GREEN}${NC}"
