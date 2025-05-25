#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 6-Step.sh;

####################################
# РЕДАКТИРОВАТЬ ТОЛЬКО ЭТОТ РАЗДЕЛ #
####################################
# Определяем машины кластера
declare -A NODES=(
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
PREFIX_CONFIG="Home"
PGADMIN_HOST="pgadmin.${PREFIX_CONFIG,,}.local"
PGADMIN_PASSWORD="MCMega2005!"

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

echo -e "${GREEN}ЭТАП 6: Установка мониторинга${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность всех узлов${NC}"
for node in "${NODES[@]}"; do
  ping -c 1 -W 1 "$node" >/dev/null || {
    echo -e "${RED}    ✗ Узел $node недоступен, установка прервана${NC}"
    exit 1
  }
done

echo -e "${GREEN}  Проверяем сертификат${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден${NC}"
  exit 1
fi

ssh -i "/root/.ssh/$CERT_NAME" "root@${NODES[s1]}" bash <<EOF
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  export PATH=$PATH:/usr/local/bin

  echo -e "${GREEN}  Добавляем репозитории и устанавливаем CloudNativePG${NC}"
  helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update &>/dev/null
  helm upgrade -i cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace \
    --set config.clusterWide=false \
    --wait --timeout 180m &>/dev/null

  echo -e "${GREEN}  Настраиваем Longhorn для работы на агентах${NC}"
  cat <<EOL | kubectl apply -f -
---
apiVersion: longhorn.io/v1beta2
kind: BackupTarget
metadata:
  name: default
  namespace: longhorn-system
spec:
  backupTargetURL: ""
  credentialSecret: ""
  pollInterval: "5m"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: replica-soft-anti-affinity
  namespace: longhorn-system
value: "false"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: storage-over-provisioning-percentage
  namespace: longhorn-system
value: "200"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: default-replica-count
  namespace: longhorn-system
value: "1"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: default-data-locality
  namespace: longhorn-system
value: "best-effort"
---
apiVersion: longhorn.io/v1beta2
kind: Setting
metadata:
  name: node-drain-policy
  namespace: longhorn-system
value: "block-if-contains-last-replica"
---
apiVersion: longhorn.io/v1beta2
kind: Node
metadata:
  name: a1
  namespace: longhorn-system
spec:
  allowScheduling: true
  tags: ["postgres-storage"]
---
apiVersion: longhorn.io/v1beta2
kind: Node
metadata:
  name: a2
  namespace: longhorn-system
spec:
  allowScheduling: true
  tags: ["postgres-storage"]
---
apiVersion: longhorn.io/v1beta2
kind: Node
metadata:
  name: a3
  namespace: longhorn-system
spec:
  allowScheduling: true
  tags: ["postgres-storage"]
EOL

  echo -e "${GREEN}  Маркируем агентские узлы для хранения данных${NC}"
  kubectl label nodes a1 a2 a3 \
    node.longhorn.io/create-default-disk=true \
    node-role.kubernetes.io/storage=true \
    --overwrite

  echo -e "${GREEN}  Создаем PostgreSQL кластер с привязкой к узлам хранилища${NC}"
  cat <<EOL | kubectl apply -f -
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgresql-cluster
  namespace: cnpg-system
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: longhorn
    storageClassParameters:
      numberOfReplicas: "1"  # Количество реплик для каждого тома
  affinity:
    topologyKey: "kubernetes.io/hostname"  # Гарантирует, что под и том будут на одном узле
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/storage
            operator: In
            values: ["true"]
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

  echo -e "${GREEN}  Создаем сервис${NC}"
  cat <<EOL | kubectl apply -n cnpg-system -f -
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-cluster-external
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
  - name: postgres
    port: 5432
    targetPort: 5432
    nodePort: 30432
  selector:
    cnpg.io/cluster: postgresql-cluster
    role: primary
EOL

  echo -e "${GREEN}  Ожидаем запуск PostgreSQL кластера${NC}"
  kubectl wait --namespace cnpg-system \
    --for=condition=Ready \
    --timeout=30m \
    cluster.postgresql.cnpg.io/postgresql-cluster &>/dev/null || {
    kubectl describe cluster.postgresql.cnpg.io/postgresql-cluster -n cnpg-system
    echo -e "${RED}  Ошибка при запуске PostgreSQL кластера${NC}"
    exit 1
  }
  kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- psql -U pas_root -d pas_cloud -c "SHOW ssl;"
  # kubectl exec -n cnpg-system postgresql-cluster-1 -c postgres -- psql -U pas_root -d pas_cloud -h localhost

  # Установка pgAdmin
  echo -e "${GREEN}  Устанавливаем pgAdmin${NC}"
  helm repo add runix https://helm.runix.net --force-update &>/dev/null
  helm upgrade -i pgadmin runix/pgadmin4 \
    --namespace cnpg-system \
    --set service.type=ClusterIP \
    --set env.email="oleg.perevyshin@gmail.com" \
    --set env.password="${PGADMIN_PASSWORD}" \
    --set serverDefinitions.enabled=false \
    --wait --timeout 60m &>/dev/null

echo -e "${GREEN}  Настраиваем и проверяем Ingress для pgAdmin${NC}"
cat <<EOL | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin-ingress
  namespace: cnpg-system
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: ${PGADMIN_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin
            port:
              number: 80
EOL

  kubectl get ingress -n cnpg-system >/dev/null

  echo -e "${GREEN}  Подключение pgAdmin к PostgreSQL${NC}"
  echo -e "${GREEN}    Внутренний DNS: postgresql-cluster-rw.cnpg-system.svc${NC}"
  echo -e "${GREEN}    Внешний доступ: ${NODES[s1]} (и другие узлы)${NC}"
  echo -e "${GREEN}    Порт: 5432${NC}"
  echo -e "${GREEN}    База: pas_cloud${NC}"
  echo -e "${GREEN}    Пользователь: pas_root${NC}"
  echo -e "${GREEN}    Пароль: K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc${NC}"

  echo -e "${GREEN}    Внешнее подключение к PostgreSQL:${NC}"
  echo -e "${GREEN}    URL: postgresql://pas_root:K7cN5n9YdJqXs3zfTCHpBAtWEi9N9VBc@${NODES[s1]}:30432/pas_cloud${NC}"
  echo -e "${GREEN}    Или через любой IP узла кластера: ${NODES[@]}${NC}"
EOF
# ----------------------------------------------------------------------------------------------- #

echo -e "${GREEN}${NC}"
echo -e "${GREEN}База данных PostgreSQL установлена${NC}"
echo -e "${GREEN}${NC}"
