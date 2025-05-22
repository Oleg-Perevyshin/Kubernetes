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
ARGOCD_HOST="argocd.${PREFIX_CONFIG}.local"

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
echo -e "${GREEN}ЭТАП 5: Установка ArgoCD${NC}"
echo -e "${GREEN}[1/9] Проверяем доступность сервера${NC}"
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
  echo -e "${GREEN}[2/9] Проверяем установку kubectl и Helm${NC}"
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
  echo -e "${GREEN}[3/9] Добавляем пространство имен${NC}"
  if ! kubectl get namespace argocd-system >/dev/null 2>&1; then
    kubectl create namespace argocd-system >/dev/null || {
      echo -e "${RED}  Ошибка создания пространства имен${NC}"
      exit 1
    }
  fi
  echo -e "${GREEN}  ✓ Пространство имен установлено${NC}"
  #
  #
  echo -e "${GREEN}[4/9] Применением ArgoCD install.yaml${NC}"
  kubectl apply -n argocd-system -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml >/dev/null || {
    echo -e "${RED}  Ошибка применения ArgoCD install.yaml${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ install.yaml применен${NC}"
  #
  #
  echo -e "${GREEN}[5/9] Ожидаем готовности ArgoCD${NC}"
  kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd-system  >/dev/null || {
    echo -e "${RED}  Ошибка запуска ArgoCD${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Поды ArgoCD запущены${NC}"
  #
  #
  echo -e "${GREEN}[6/9] Настраиваем Ingress для ArgoCD${NC}"
  cat <<EOL | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: ${ARGOCD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
EOL
  echo -e "${GREEN}  ✓ Ingress для ArgoCD настроен${NC}"
  #
  #
  echo -e "${GREEN}[7/9] Создаем самоподписанный TLS-сертификат для ArgoCD${NC}"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/argocd.key \
    -out /tmp/argocd.crt \
    -subj "/CN=${ARGOCD_HOST}" \
    -addext "subjectAltName=DNS:${ARGOCD_HOST}" >/dev/null || {
    echo -e "${RED}  Ошибка генерации сертификата${NC}"
    exit 1
  }
  kubectl create secret tls argocd-tls -n argocd-system \
    --key /tmp/argocd.key \
    --cert /tmp/argocd.crt >/dev/null || {
    echo -e "${RED}  Ошибка создания TLS-секрета${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ TLS-сертификат для ArgoCD создан и размещен в секретах${NC}"
  #
  #
  echo -e "${GREEN}[8/9] Обновляем Ingress для использования HTTPS${NC}"
  kubectl patch ingress argocd -n argocd-system --type=json -p='[
    {"op": "add", "path": "/spec/tls", "value": [{
      "hosts": ["'"${ARGOCD_HOST}"'"],
      "secretName": "argocd-tls"
    }]}
  ]'  >/dev/null || {
    echo -e "${RED}  Ошибка обновления Ingress${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Ingress обновлен${NC}"
  #
  #
  echo -e "${GREEN}[9/9] Проверяем создание Ingress${NC}"
  kubectl get ingress -n argocd-system >/dev/null || {
    echo -e "${RED}  Ошибка создания Ingress${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Ingress успешно проверен${NC}"
  #
  #
  echo -e "${YELLOW}  Логин: admin | Пароль: \$(kubectl -n argocd-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"
EOF

echo -e "${GREEN}${NC}"
echo -e "${GREEN}ArgoCD установлен и доступен по адресу: https://${ARGOCD_HOST}${NC}"
echo -e "${GREEN}${NC}"
