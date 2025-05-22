#!/bin/bash

# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"
PREFIX_CONFIG="home"

# Машины кластера
if [[ "$PREFIX_CONFIG" == "home" ]]; then
  declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
elif [[ "$PREFIX_CONFIG" == "office" ]]; then
  declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
else
  echo -e "${RED}Неизвестный кластер $PREFIX_CONFIG, установка прервана${NC}"
  exit 1
fi

echo -e "${GREEN}ЭТАП 3: Установка Cert-Manager${NC}"
echo -e "${GREEN}[1/4] Проверяем доступность сервера${NC}"
ping -c 1 -W 1 "${NODES[server]}" >/dev/null || {
  echo -e "${RED}  Сервер ${NODES[server]} недоступен${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Сервер ${NODES[server]} доступен${NC}"
#
#
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  echo -e "${GREEN}[2/4] Проверяем установку kubectl и helm${NC}"
  for cmd in kubectl helm; do
    if ! command -v "\$cmd" &> /dev/null; then
      echo -e "\${RED}  \${cmd} не установлен, установка прервана\${NC}"; exit 1;
    fi
  done
  echo -e "${GREEN}  ✓ kubectl и helm установлены${NC}"
  #
  #
  echo -e "${GREEN}[3/4] Добавляем репозиторий Jetstack${NC}"
  if helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null; then
    echo -e "${GREEN}  ✓ Репозиторий добавлен${NC}"
  else
    echo -e "${RED}  Ошибка добавления репозитория Jetstack, установка прервана${NC}"; exit 1;
  fi
  #
  #
  echo -e "${GREEN}[4/4] Устанавливаем Cert-Manager${NC}"
  helm upgrade -i cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --wait --timeout 180m >/dev/null || {
    echo -e "${RED}  Ошибка установки Cert-Manager, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Cert-Manager успешно установлен${NC}"
  echo -e "${GREEN}${NC}"
EOF
