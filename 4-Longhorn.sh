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
LONGHORN_HOST="longhorn.${PREFIX_CONFIG}.local"

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
echo -e "${GREEN}ЭТАП 4: Установка Longhorn${NC}"
echo -e "${GREEN}[1/6] Проверяем доступность сервера${NC}"
ping -c 1 -W 1 "${NODES[server]}" >/dev/null || {
  echo -e "${RED}  Сервер ${NODES[server]} недоступен${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Сервер ${NODES[server]} доступен${NC}"
#
#
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  # Прекращение выполнения при любой ошибке
  set -euo pipefail
  #
  #
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
  #
  #
  echo -e "${GREEN}[2/6] Проверяем установку kubectl и Helm${NC}"
  if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}  kubectl не установлен, установка прервана${NC}"
    exit 1
  fi
  if ! command -v helm &> /dev/null; then
    echo -e "${RED}  helm не установлен, установка прервана${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ kubectl и Helm установлены${NC}"
  #
  #
  echo -e "${GREEN}[3/6] Добавляем репозитории Longhorn${NC}"
  helm repo add longhorn https://charts.longhorn.io --force-update >/dev/null || {
    echo -e "${RED}  Ошибка при добавлении репозитория Longhorn, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Репозиторий добавлен${NC}"
  #
  #
  echo -e "${GREEN}[4/6] Устанавливаем Longhorn${NC}";
  helm upgrade -i longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --set csi.enabled=true \
  --set defaultSettings.backupTarget="" \
  --wait --timeout 180m >/dev/null || {
    echo -e "${RED}  Ошибка при установке Longhorn, установка прервана${NC}"
    exit 1
  }
  #
  #
  echo -e "${GREEN}[5/6] Настраиваем Ingress для Longhorn${NC}"
  cat <<EOL | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn
  namespace: longhorn-system
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: ${LONGHORN_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: longhorn-frontend
            port:
              number: 80
  tls:
  - hosts:
    - ${LONGHORN_HOST}
    secretName: longhorn-tls
EOL
  echo -e "${GREEN}  ✓ Ingress для Longhorn настроен${NC}"
  #
  #
  echo -e "${GREEN}[6/6] Проверяем Ingress Longhorn${NC}"
  kubectl get ingress longhorn -n longhorn-system -o wide || {
    echo -e "${RED}  Ошибка проверки Ingress${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Ingress Longhorn успешно запущен${NC}"
EOF
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Longhorn установлен${NC}"
echo -e "${GREEN}${NC}"
