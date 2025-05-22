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
echo -e "${GREEN}ЭТАП 5: Установка CloudNativePG${NC}"
echo -e "${GREEN}[1/8] Проверяем доступность сервера${NC}"
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
  echo -e "${GREEN}[2/8] Проверяем установку kubectl и Helm${NC}"
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
  echo -e "${GREEN}[3/8] Добавляем репозитории${NC}"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория CloudNativePG${NC}"
    exit 1
  }
  helm repo add runix https://helm.runix.net >/dev/null || {
    echo -e "${RED}  Ошибка добавления репозитория pgAdmin${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Репозитории успешно добавлены${NC}"

  # Установка CloudNativePG
  echo -e "${GREEN}[4/8] Устанавливаем CloudNativePG${NC}"
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace \
    --wait --timeout 180m >/dev/null || {
    echo -e "${RED}  Ошибка при установке CloudNativePG${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ CloudNativePG успешно установлен${NC}"

  # Настройка Longhorn BackupTarget
  echo -e "${GREEN}[5/8] Настраиваем Longhorn BackupTarget${NC}"
  cat <<EOL | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: ""
  credentialSecret: ""
  pollInterval: "5m"
EOL

  # Создание PostgreSQL кластера
  echo -e "${GREEN}[6/8] Создаем PostgreSQL кластер${NC}"
  cat <<EOL | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql-cluster
  namespace: cnpg-system
spec:
  instances: 3
  storage:
    size: 1Gi
    storageClass: longhorn
  monitoring:
    enablePodMonitor: true
  bootstrap:
    initdb:
      database: pas_cloud
      owner: pas_root
      secret:
        name: postgres-credentials
  postgresql:
    pg_hba:
      - host all all all md5
      - local all all md5
    parameters:
      max_connections: "100"
      shared_buffers: "512MB"
      work_mem: "16MB"
---
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: cnpg-system
type: kubernetes.io/basic-auth
stringData:
  username: pas_root
  password: K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc
EOL

  # Создание сервиса
  cat <<EOL | kubectl apply -n cnpg-system -f -
apiVersion: v1
kind: Service
metadata:
  name: postgresql-cluster-external
spec:
  type: NodePort
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
    nodePort: 30432
  selector:
    cnpg.io/cluster: postgresql-cluster
    role: primary
EOL

  echo -e "${YELLOW}  Ожидаем запуск${NC}"
  kubectl wait --namespace cnpg-system \
    --for=condition=Ready \
    --timeout=30m \
    cluster.postgresql.cnpg.io/postgresql-cluster >/dev/null || {
    kubectl describe cluster.postgresql.cnpg.io/postgresql-cluster -n cnpg-system
    echo -e "${RED}  Ошибка при запуске PostgreSQL кластера${NC}"
    exit 1
  }
  kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- psql -U pas_root -d pas_cloud -c "SHOW ssl;"
  # kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- psql -U pas_root -d pas_cloud -h localhost
  echo -e "${GREEN}  ✓ PostgreSQL кластер запущен${NC}"

  # Установка pgAdmin
  echo -e "${GREEN}[7/8] Устанавливаем pgAdmin${NC}"
  helm upgrade --install pgadmin runix/pgadmin4 \
    --namespace cnpg-system \
    --set service.type=NodePort \
    --set service.nodePort=30888 \
    --set env.email="oleg.perevyshin@gmail.com" \
    --set env.password="MCMega2005!" \
    --set serverDefinitions.servers.postgres.Host="postgresql.home.local" \
    --set serverDefinitions.servers.postgres.Port="5432" \
    --set serverDefinitions.servers.postgres.Username="pas_root" \
    --set serverDefinitions.servers.postgres.Password="K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc" \
    --set serverDefinitions.servers.postgres.MaintenanceDB="pas_cloud" \
    --wait \
    --timeout 180m >/dev/null || {
    echo -e "${RED}  Ошибка при установке pgAdmin${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ pgAdmin успешно установлен${NC}"
  echo -e "${YELLOW}  Логин: oleg.perevyshin@gmail.com | Пароль: MCMega2005!${NC}"
  echo -e "${YELLOW}  Доступ к pgAdmin: http://${NODES[server]}:30888${NC}"

  # Данные для подключения к PostgreSQL
  echo -e "${GREEN}[8/8] Настройка подключения pgAdmin к PostgreSQL${NC}"
  echo -e "${YELLOW}Данные для подключения:${NC}"
  echo -e "${YELLOW}Хост: postgresql.home.local${NC}"
  echo -e "${YELLOW}Порт: 5432${NC}"
  echo -e "${YELLOW}База: pas_cloud${NC}"
  echo -e "${YELLOW}Пользователь: pas_root${NC}"
  echo -e "${YELLOW}Пароль: K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc${NC}"
  echo -e "${GREEN}Внешнее подключение к PostgreSQL:${NC}"
  echo -e "${YELLOW}URL: postgresql://pas_root:K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc@${NODES[server]}:30432/pas_cloud${NC}"
  echo -e "${YELLOW}Или через любой IP узла кластера: ${NODES[@]}${NC}"
  echo -e "${YELLOW}URL для Prisma: postgresql://pas_root:K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc@${NODES[server]}:30432/pas_cloud?sslmode=require${NC}"
EOF

echo -e "${GREEN}${NC}"
echo -e "${GREEN}CloudNativePG установлен${NC}"
echo -e "${GREEN}${NC}"
