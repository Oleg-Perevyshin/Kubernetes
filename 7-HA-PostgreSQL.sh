#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 7-HA-PostgreSQL.sh;

# Определяем машины кластера
declare -A NODES=(
  [vip]="192.168.5.40"
  [s1]="192.168.5.31"
  [s2]="192.168.5.32"
  [s3]="192.168.5.33"
  [a1]="192.168.5.34"
  [a2]="192.168.5.35"
  [a3]="192.168.5.36"
)
ORDERED_NODES=("${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="/root/.ssh/id_rsa_cluster"
PGADMIN_HOST="pgadmin.poe-gw.keenetic.pro"
PGADMIN_PORT="30500"
PGADMIN_PASSWORD="!MCMega2005!"
PG_SIZE="75Gi"
CLOUD_DB="pas_cloud_db"
CLOUD_USER="pas_cloud_user"
CLOUD_PASSWORD="TbSJ3dar9ONNbc43aU7ayOYHIb9fhY3e"
POSTGRES_PORT="30543"

#############################################
#             НИЧЕГО НЕ МЕНЯТЬ              #
#############################################
# Прекращение выполнения при любой ошибке и цвета для вывода
set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}ЭТАП 7: Установка база данных PostgreSQL${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -i "${CERT_NAME}" "root@${NODES[s1]}" bash <<POSTGRESQL
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  if ! kubectl get storageclass longhorn &>/dev/null; then
    echo -e "${RED}  Longhorn не найден, установка прервана${NC}"
    exit 1
  fi

  echo -e "${GREEN}  Добавляем репозитории и устанавливаем CloudNative-PG${NC}"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update &>/dev/null
  helm repo update
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
  password: "${PGADMIN_PASSWORD}"
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
    size: ${PG_SIZE}
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
        - CREATE DATABASE "${CLOUD_DB}";
        - CREATE USER "${CLOUD_USER}" WITH PASSWORD '${CLOUD_PASSWORD}';
        - ALTER USER "${CLOUD_USER}" CREATEDB;
        - GRANT ALL PRIVILEGES ON DATABASE "${CLOUD_DB}" TO "${CLOUD_USER}";
        - ALTER DATABASE "${CLOUD_DB}" OWNER TO "${CLOUD_USER}";
        - GRANT ALL ON SCHEMA public TO "${CLOUD_USER}";
        - GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "${CLOUD_USER}";
        - GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "${CLOUD_USER}";
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${CLOUD_USER}";
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${CLOUD_USER}";
  enableSuperuserAccess: true
  superuserSecret:
    name: pg-superuser
  postgresql:
    pg_hba:
      - host all all all md5
      - host all all 127.0.0.1/32 md5
      - local all all md5
    parameters:
      ssl_min_protocol_version: "TLSv1.2"
      ssl_max_protocol_version: "TLSv1.3"
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
  helm repo update
  helm upgrade -i pgadmin runix/pgadmin4 \
    --namespace cnpg-system --create-namespace \
    --set env.email="oleg.perevyshin@gmail.com" \
    --set env.password="${PGADMIN_PASSWORD}" \
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

  echo -e "${GREEN}  Сохраняем файл сертификата базы данных /root/ca.crt на первом сервере${NC}"
  kubectl -n cnpg-system get secret postgresql-cluster-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /root/ca.crt
  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Общие параметры подключения: ${NODES[vip]}:${POSTGRES_PORT} | Пользователь: postgres | Пароль: ${PGADMIN_PASSWORD}${NC}"
  echo -e "${GREEN}  Web доступ: http://${NODES[vip]}:${PGADMIN_PORT} | https://${PGADMIN_HOST} (Пользователь: oleg.perevyshin@gmail.com | Пароль: ${PGADMIN_PASSWORD})${NC}"
  echo -e "${GREEN}  App доступ: postgresql://${CLOUD_USER}:${CLOUD_PASSWORD}@${NODES[vip]}:${POSTGRES_PORT}/${CLOUD_DB}${NC}"
  echo -e "${GREEN}${NC}"
POSTGRESQL
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Получаем файл сертификата базы данных /root/.kube/ca.crt${NC}"
ssh -i "$CERT_NAME" "root@${NODES[s1]}" "cat /root/ca.crt" > "/root/.kube/ca.crt"
echo -e "${GREEN}  Файл необходимо скопировать в /prisma/ca.crt проекта${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}База данных PostgreSQL установлена${NC}"
echo -e "${GREEN}${NC}"
