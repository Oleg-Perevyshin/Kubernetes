#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 7-HA-PostgreSQL.sh;

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [vip]="192.168.5.20"
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)
ORDERED_NODES=("${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
PREFIX_CONFIG="Home"
PGADMIN_HOST="pgadmin.poe-gw.keenetic.pro"
PGADMIN_PORT="30500"
PG_PASSWORD="MCMega2005!"
PAS_DB="pas_cloud_db"
PAS_USER="pas_cloud_user"
PAS_PASSWORD="TbSJ3dar9ONNbc43aU7ayOYHIb9fhY3e"
POSTGRES_PORT="30543"

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

echo -e "${GREEN}ЭТАП 7: Установка база данных PostgreSQL${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -i "/root/.ssh/${CERT_NAME}" "root@${NODES[s1]}" bash <<POSTGRESQL
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  if ! kubectl get storageclass longhorn &>/dev/null; then
    echo -e "${RED}  Longhorn не найден, установка прервана${NC}"
    exit 1
  fi

  echo -e "${GREEN}  Добавляем репозитории и устанавливаем CloudNative-PG${NC}"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update &>/dev/null
  helm upgrade -i cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace \
    --set config.clusterWide=true \
    --wait --timeout 10m >/dev/null

  echo -e "${GREEN}  Создаем PostgreSQL кластер${NC}"
  cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-postgresql
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "1"
  dataLocality: "strict-local"
  staleReplicaTimeout: "1440"
allowVolumeExpansion: true
---
apiVersion: v1
kind: Secret
metadata:
  name: pg-superuser
  namespace: cnpg-system
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: ${PG_PASSWORD}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql-cluster
  namespace: cnpg-system
spec:
  instances: 3
  primaryUpdateStrategy: unsupervised
  storage:
    size: 5Gi
    storageClass: longhorn-postgresql
  affinity:
    topologyKey: "kubernetes.io/hostname"
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: longhorn
            operator: In
            values: ["true"]
  monitoring:
    enablePodMonitor: true
  bootstrap:
    initdb:
      postInitSQL:
        - CREATE DATABASE ${PAS_DB};
        - CREATE USER ${PAS_USER} WITH PASSWORD '${PAS_PASSWORD}';
        - GRANT ALL PRIVILEGES ON DATABASE ${PAS_DB} TO ${PAS_USER};
        - ALTER DATABASE ${PAS_DB} OWNER TO ${PAS_USER};
        - GRANT ALL ON SCHEMA public TO ${PAS_USER};
        - GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PAS_USER};
        - GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PAS_USER};
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PAS_USER};
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${PAS_USER};

  enableSuperuserAccess: true
  superuserSecret:
    name: pg-superuser
  postgresql:
    pg_hba:
      - host all all all md5
      - host all all 127.0.0.1/32 md5
      - local all all md5
    parameters:
      max_connections: "200"
      shared_buffers: "512MB"
      work_mem: "16MB"
      max_wal_senders: "10"
      wal_level: "logical"
EOF

  echo -e "${GREEN}  Создаем сервис для внешнего доступа${NC}"
  cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-loadbalancer
  namespace: cnpg-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
    service.beta.kubernetes.io/kube-vip-honour-labels: "true"
    cnpg.io/cluster: "postgresql-cluster"
spec:
  type: LoadBalancer
  loadBalancerIP: ${NODES[vip]}
  ports:
  - name: postgresql
    port: ${POSTGRES_PORT}
    targetPort: 5432
    protocol: TCP
  selector:
    cnpg.io/cluster: postgresql-cluster
    cnpg.io/instanceRole: primary
EOF

  echo -e "${GREEN}  Ожидаем запуск кластера и проверяем подключение${NC}"
  kubectl -n cnpg-system wait --for=condition=Ready cluster.postgresql.cnpg.io/postgresql-cluster --timeout=30m >/dev/null
  if ! kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- pg_isready -h localhost -U postgres >/dev/null; then
    echo -e "${RED}    ✗ Не удалось подключиться к PostgreSQL, установка прервана${NC}"
    exit 1
  fi

  echo -e "${GREEN}  Устанавливаем pgAdmin${NC}"
  helm repo add runix https://helm.runix.net --force-update &>/dev/null
  helm upgrade -i pgadmin runix/pgadmin4 \
    --namespace cnpg-system --create-namespace \
    --set env.email="oleg.perevyshin@gmail.com" \
    --set env.password="${PG_PASSWORD}" \
    --set serverDefinitions.enabled=false \
    --set persistentVolume.enabled=true \
    --set persistentVolume.size=1Gi \
    --set persistence.storageClass=longhorn \
    --wait --timeout 10m >/dev/null

  echo -e "${GREEN}  Настраиваем сервис для HTTP доступа${NC}"
  cat <<EOF | kubectl apply -f - >/dev/null
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin-loadbalancer
  namespace: cnpg-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip]}"
spec:
  type: LoadBalancer
  loadBalancerIP: ${NODES[vip]}
  ports:
  - name: pgadmin
    port: ${PGADMIN_PORT}
    targetPort: 80
    protocol: TCP
  selector:
    app.kubernetes.io/name: pgadmin4
EOF

  echo -e "${GREEN}  Проверяем состояние pgAdmin${NC}"
  kubectl -n cnpg-system wait --for=condition=Ready pod -l app.kubernetes.io/name=pgadmin4 --timeout=5m &>/dev/null

  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Информация для подключения:${NC}"
  echo -e "${GREEN}    PostgreSQL (супер пользователь):${NC}"
  echo -e "${GREEN}      Хост: ${NODES[vip]} | Порт: ${POSTGRES_PORT}${NC}"
  echo -e "${GREEN}      Пользователь: postgres | Пароль: ${PG_PASSWORD}${NC}"
  echo -e "${GREEN}    Web интерфейс (pgAdmin):${NC}"
  echo -e "${GREEN}      URL: http://${NODES[vip]}:${PGADMIN_PORT} | https://${PGADMIN_HOST}${NC}"
  echo -e "${GREEN}      Пользователь: oleg.perevyshin@gmail.com | Пароль: ${PG_PASSWORD}${NC}"
  echo -e "${GREEN}    URL для подключения из приложения PAS Cloud:${NC}"
  echo -e "${GREEN}      postgresql://${PAS_USER}:${PAS_PASSWORD}@${NODES[vip]}:${POSTGRES_PORT}/${PAS_DB}${NC}"
POSTGRESQL
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}База данных PostgreSQL установлена${NC}"
echo -e "${GREEN}${NC}"
