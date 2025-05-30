#!/bin/bash

# Прекращение выполнения при любой ошибке
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"
PREFIX_CONFIG="home"
RANCHER_HOST="rancher.${PREFIX_CONFIG}.local"
RANCHER_PASSWORD="MCMega2005!"

# Машины кластера
if [[ "$PREFIX_CONFIG" == "home" ]]; then
  declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")
elif [[ "$PREFIX_CONFIG" == "office" ]]; then
  declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
else
  echo -e "${RED}Неизвестный кластер $PREFIX_CONFIG, установка прервана${NC}"
  exit 1
fi

echo -e "${GREEN}ЭТАП 3: Установка Rancher${NC}"
echo -e "${GREEN}[1/3] Проверяем доступность сервера${NC}"
ping -c 1 -W 1 "${NODES[server]}" >/dev/null || {
  echo -e "${RED}  Сервер ${NODES[server]} недоступен${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Сервер ${NODES[server]} доступен${NC}"

# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  # Прекращение выполнения при любой ошибке
  set -euo pipefail
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  #
  #
  echo -e "${GREEN}[2/3] Проверяем установку kubectl и helm${NC}"
  if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}  kubectl не установлен, установка прервана${NC}"
    exit 1
  fi
  if ! command -v helm &> /dev/null; then
    echo -e "${RED}  helm не установлен, установка прервана${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ kubectl и helm установлены${NC}"
  #
  #
  echo -e "${GREEN}[3/3] Добавляем репозиторий Traefik и устанавливаем${NC}"
  helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория Traefik, установка прервана${NC}"
    exit 1
  }

  helm upgrade -i traefik traefik/traefik \
    --namespace traefik-system --create-namespace \
    --set service.type=NodePort \
    --set ports.web.enabled=true \
    --set ports.websecure.enabled=true \
    --set entryPoints.web.redirect.entryPoint=websecure \
    --wait --timeout 180m >/dev/null || {
      echo -e "${RED}  Ошибка установки Traefik, установка прервана${NC}"
      exit 1
    }
EOF

echo -e "${GREEN}Traefik успешно установлен!${NC}"
