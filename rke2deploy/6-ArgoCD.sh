#!/bin/bash
# Вызвываем chmod +x 6-ArgoCD.sh; из командной строки чтоб сделать файл исполняемым

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
ARGOCD_HOST="argocd.${PREFIX_CONFIG}.local"
ARGOCD_PASSWORD="MCMega2005!"

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
  echo -e "${GREEN}  Добавляем пространство имен для ArgoCD${NC}";
  if ! kubectl get namespace argocd >/dev/null 2>&1; then
    kubectl create namespace argocd >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка создания пространства имен${NC}"
      exit 1
    }
  fi
  #
  #
  echo -e "${GREEN}  Устанавливаем кастомный пароль для admin${NC}";
  kubectl create secret generic argocd-initial-admin-secret -n argocd \
    --from-literal=password="$(echo -n "\$ARGOCD_PASSWORD" | base64 -w0)" \
    --dry-run=client -o yaml | kubectl apply -f - || {
    echo -e "${RED}  Ошибка создания секрета с паролем${NC}"
    exit 1
  }
  #
  #
  echo -e "${GREEN}  Применением ArgoCD install.yaml${NC}";
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || {
    echo -e "${RED}  Ошибка применения ArgoCD install.yaml${NC}"
    exit 1
  }
  echo -e "${GREEN}  Ждём готовности подов ArgoCD...${NC}";
  kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || {
    echo -e "${RED}  Ошибка ожидания готовности ArgoCD${NC}"
    exit 1
  }
  #
  #
  echo -e "${GREEN}  Настраиваем Ingress для ArgoCD${NC}";
  cat <<EOL | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-ingress
  namespace: argocd
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

  echo -e "${GREEN}  Создаем самоподписанный TLS-сертификат для ArgoCD${NC}";
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /tmp/argocd.key \
    -out /tmp/argocd.crt \
    -subj "/CN=${ARGOCD_HOST}" \
    -addext "subjectAltName=DNS:${ARGOCD_HOST}" 2>/dev/null || {
    echo -e "${RED}  Ошибка генерации сертификата${NC}"
    exit 1
  }

  kubectl create secret tls argocd-tls -n argocd \
    --key /tmp/argocd.key \
    --cert /tmp/argocd.crt 2>/dev/null || {
    echo -e "${RED}  Ошибка создания TLS-секрета${NC}"
    exit 1
  }

  echo -e "${GREEN}  Обновляем Ingress для использования HTTPS${NC}";
  kubectl patch ingress argocd-ingress -n argocd --type=json -p='[
    {"op": "add", "path": "/spec/tls", "value": [{
      "hosts": ["'"${ARGOCD_HOST}"'"],
      "secretName": "argocd-tls"
    }]}
  ]' || {
    echo -e "${RED}  Ошибка обновления Ingress${NC}"
    exit 1
  }

  echo -e "${GREEN}  Проверяем создание Ingress${NC}";
  kubectl get ingress -n argocd || {
    echo -e "${RED}  Ошибка создания Ingress${NC}"
    exit 1
  }

  echo -e "${GREEN}  Получаем пароль администратора ArgoCD${NC}";
  ARGOCD_PASSWORD=\$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo -e "${YELLOW}  Логин: admin | Пароль: \$ARGOCD_PASSWORD${NC}"
EOF

echo -e "${GREEN}${NC}"
echo -e "${GREEN}ArgoCD установлен и доступен по адресу: https://${ARGOCD_HOST}${NC}"
echo -e "${GREEN}${NC}"
