#!/bin/bash
# chmod +x 7-THA-PostgreSQL.sh

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.21" [s2]="192.168.5.22" [s3]="192.168.5.23" # ControlPlane
  [w1]="192.168.5.24" [w2]="192.168.5.25" [w3]="192.168.5.26" # Worker
  [backup]="192.168.5.29"                                     # Backup/Longhorn
  [vip-api]="192.168.5.30"                                    # API-сервера Talos
  [vip-service]="192.168.5.31"                                # LoadBalancer
)
ORDERED_NODES=(
  "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}"
  "${NODES[w1]}" "${NODES[w2]}" "${NODES[w3]}"
  "${NODES[backup]}" "${NODES[vip-api]}" "${NODES[vip-service]}"
)
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

PGADMIN_HOST="pgadmin.poe-gw.keenetic.pro"
PGADMIN_PORT="30500"
PG_PASSWORD="!MCMega2005!"
PAS_DB="pas_cloud_db"
PAS_USER="pas_cloud_user"
PAS_PASSWORD="TbSJ3dar9ONNbc43aU7ayOYHIb9fhY3e"
POSTGRES_PORT="30543"
POSTGRES_SIZE="50Gi"

#############################################
echo -e "${GREEN}ЭТАП 7: Установка PostgreSQL${NC}"
echo -e "${GREEN}  Проверяем доступность узлов кластера${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done

kubectl get storageclass longhorn &>/dev/null || { echo -e "${RED}  Longhorn не найден, установка прервана${NC}"; exit 1; }

echo -e "${GREEN}  Устанавливаем CloudNative-PG${NC}"
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace \
  --set config.clusterWide=true \
  --wait --timeout 10m >/dev/null || { echo -e "${RED}    ✗ Ошибка установки CloudNative-PG${NC}"; exit 1; }

echo -e "${GREEN}  Создаем PostgreSQL кластер${NC}"
cat <<PG_CLASTER | kubectl apply -f - >/dev/null
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
  password: "${PG_PASSWORD}"
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
    size: "${POSTGRES_SIZE}"
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
        - ALTER USER ${PAS_USER} CREATEDB;
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
      ssl_min_protocol_version: "TLSv1.2"
      ssl_max_protocol_version: "TLSv1.3"
      max_connections: "200"
      shared_buffers: "512MB"
      work_mem: "16MB"
      max_wal_senders: "10"
      wal_level: "logical"
PG_CLASTER

echo -e "${GREEN}  Создаем сервис для доступа${NC}"
cat <<SERVICE | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: postgresql-loadbalancer
  namespace: cnpg-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip-service]}"
    service.beta.kubernetes.io/kube-vip-honour-labels: "true"
    cnpg.io/cluster: "postgresql-cluster"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip-service]}"
  ports:
    - name: postgresql
      port: ${POSTGRES_PORT}
      targetPort: 5432
      protocol: TCP
  selector:
    cnpg.io/cluster: postgresql-cluster
    cnpg.io/instanceRole: primary
SERVICE

echo -e "${GREEN}  Ожидаем запуск кластера и проверяем подключение${NC}"
kubectl -n cnpg-system wait --for=condition=Ready cluster.postgresql.cnpg.io/postgresql-cluster --timeout=30m >/dev/null
if ! kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- pg_isready -h localhost -U postgres >/dev/null; then
  echo -e "${RED}    ✗ Не удалось подключиться к PostgreSQL, установка прервана${NC}"; exit 1;
fi

echo -e "${GREEN}  Устанавливаем pgAdmin${NC}"
helm repo add runix https://helm.runix.net --force-update &>/dev/null
helm repo update &>/dev/null
helm upgrade -i pgadmin runix/pgadmin4 \
  --namespace cnpg-system --create-namespace \
  --set env.email="oleg.perevyshin@gmail.com" \
  --set env.password="${PG_PASSWORD}" \
  --set serverDefinitions.enabled=false \
  --set persistentVolume.enabled=true \
  --set persistentVolume.size=1Gi \
  --set persistence.storageClass=longhorn \
  --wait --timeout 10m &>/dev/null || { echo -e "${RED}    ✗ Ошибка установки pgAdmin${NC}"; exit 1; }
echo -e "${GREEN}  Создаём Service${NC}"
cat <<PGADMIN | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: pgadmin-lb
  namespace: cnpg-system
  annotations:
    service.beta.kubernetes.io/kube-vip-loadbalancer-ip: "${NODES[vip-service]}"
spec:
  type: LoadBalancer
  loadBalancerIP: "${NODES[vip-service]}"
  ports:
    - name: pgadmin
      port: ${PGADMIN_PORT}
      targetPort: 80
      protocol: TCP
  selector:
    app.kubernetes.io/name: pgadmin4
PGADMIN
echo -e "${GREEN}  Проверяем состояние pgAdmin${NC}"
kubectl -n cnpg-system wait --for=condition=Ready pod -l app.kubernetes.io/name=pgadmin4 --timeout=5m &>/dev/null

echo -e "${GREEN}  Получаем файл сертификата базы данных${NC}"
kubectl -n cnpg-system get secret postgresql-cluster-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
echo -e "${GREEN}  Файл необходимо скопировать в /prisma/ca.crt проекта${NC}"

echo -e "${GREEN}  Информация для подключения:${NC}"
echo -e "${GREEN}    PostgreSQL (супер пользователь):${NC}"
echo -e "${GREEN}      Хост: ${NODES[vip-service]} | Порт: ${POSTGRES_PORT}${NC}"
echo -e "${GREEN}      Пользователь: postgres | Пароль: ${PG_PASSWORD}${NC}"
echo -e "${GREEN}    Web интерфейс (pgAdmin):${NC}"
echo -e "${GREEN}      URL: http://${NODES[vip-service]}:${PGADMIN_PORT} | https://${PGADMIN_HOST}${NC}"
echo -e "${GREEN}      Пользователь: oleg.perevyshin@gmail.com | Пароль: ${PG_PASSWORD}${NC}"
echo -e "${GREEN}    URL для подключения из приложения PAS Cloud:${NC}"
echo -e "${GREEN}      postgresql://${PAS_USER}:${PAS_PASSWORD}@${NODES[vip-service]}:${POSTGRES_PORT}/${PAS_DB}${NC}"

rm -rf /root/.kube/cache
echo -e "${GREEN}База данных PostgreSQL установлена${NC}"; echo -e "${GREEN}${NC}"
