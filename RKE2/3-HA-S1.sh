#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 3-HA-S1.sh;

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.31" [s2]="192.168.5.32" [s3]="192.168.5.33"
  [vip]="192.168.5.40"
)
VIP_INTERFACE="ens18"
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
PREFIX_CONFIG="HomeLab"
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'

#############################################
echo -e "${GREEN}ЭТАП 3: Подготовка первого сервера RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" bash <<SETUP_S1
  echo -e "${GREEN}  Устанавливаем RKE2...${NC}"
  set -euo pipefail
  export PATH=\$PATH:/usr/local/bin
  mkdir -p /root/.kube
  mkdir -p /etc/rancher/rke2/
  mkdir -p /var/lib/rancher/rke2/server/manifests/
  cat <<CONFIG > /etc/rancher/rke2/config.yaml
node-ip: "${NODES[s1]}"
tls-san:
  - "${NODES[vip]}"
  - "${NODES[s1]}"
  - "${NODES[s2]}"
  - "${NODES[s3]}"
write-kubeconfig-mode: 600
etcd-expose-metrics: true
CONFIG
  tar xzf /root/rke2.linux-amd64.tar.gz -C /usr/local
  ln -sf /usr/local/bin/rke2 /usr/local/bin/rke2-server
  cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now rke2-server.service
  for i in {1..30}; do
    [ -f /etc/rancher/rke2/rke2.yaml ] && break
    [ "\$i" -eq 30 ] && echo -e "${RED}    ✗ rke2.yaml не создан, установка прервана${NC}" && exit 1
    sleep 10
  done

  echo -e "${GREEN}  Настраиваем окружение${NC}"
  grep -q "KUBECONFIG=" /root/.bashrc || echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc
  ln -sf /etc/rancher/rke2/rke2.yaml /root/.kube/config
  grep -q "rke2/bin" /root/.bashrc || echo 'export PATH=\$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc
  [ -f /var/lib/rancher/rke2/bin/kubectl ] && ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl

  echo -e "${GREEN}  Устанавливаем kube-vip${NC}"
  command -v jq >/dev/null || { echo -e "${RED}    ✗ jq не установлен, установка прервана${NC}"; exit 1; }
  command -v docker >/dev/null || { echo -e "${RED}    ✗ Docker не установлен, установка прервана${NC}"; exit 1; }
  command -v kubectl >/dev/null || { echo -e "${RED}    ✗ kubectl не найден, установка прервана${NC}"; exit 1; }
  kubectl delete daemonset kube-vip-ds -n kube-system --ignore-not-found >/dev/null
  kubectl apply -f https://kube-vip.io/manifests/rbac.yaml >/dev/null
  VIP_VERSION=\$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r '.[0].name')
  [ -z "\$VIP_VERSION" ] && echo -e "${RED}    ✗ Не удалось получить версию kube-vip, установка прервана${NC}" && exit 1
  docker run --network host --rm ghcr.io/kube-vip/kube-vip:\$VIP_VERSION manifest daemonset \
    --interface ${VIP_INTERFACE} \
    --address ${NODES[vip]} \
    --inCluster \
    --controlplane \
    --services \
    --arp \
    --leaderElection 2>/dev/null | kubectl apply -f - >/dev/null
SETUP_S1
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Копируем конфигурацию кластера на мастер-машину${NC}"
mkdir -p "/root/.kube"
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" "cat /var/lib/rancher/rke2/server/token" > "/root/.kube/${PREFIX_CONFIG}_Token"
ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" "cat /etc/rancher/rke2/rke2.yaml" > "/root/.kube/${PREFIX_CONFIG}_Config.yaml"
sed -i -e "s/127.0.0.1/${NODES[vip]}/g" \
       -e "0,/name: default/s//name: ${PREFIX_CONFIG}-RKE2/" \
       -e "s/cluster: default/cluster: ${PREFIX_CONFIG}-RKE2/" \
       "/root/.kube/${PREFIX_CONFIG}_Config.yaml"
chown "$(id -u):$(id -g)" "/root/.kube/${PREFIX_CONFIG}_Config.yaml"

echo -e "${GREEN}  Ожидаем готовности API-сервера${NC}"
for i in {1..30}; do
  if curl -sk https://${NODES[vip]}:6443/livez &>/dev/null; then break; fi
  echo -e "${YELLOW}  Сервер ещё не готов, попытка $i...${NC}"
  [ "$i" -eq 30 ] && echo -e "${RED}  Сервер не запустился, установка прервана${NC}" && exit 1
  sleep 10
done

echo -e "${GREEN}  Проверяем, что rke2-server.service активен на первом сервере${NC}"
for i in {1..10}; do
  ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" "systemctl is-active --quiet rke2-server.service" && break
  echo -e "${YELLOW}  rke2-server.service ещё не активен, попытка $i...${NC}"
  [ "$i" -eq 10 ] && echo -e "${RED}  rke2-server.service не запустился, установка прервана${NC}" && exit 1
  sleep 5
done

echo -e "${GREEN}  Проверяем, что узел зарегистрирован и в состоянии Ready${NC}"
NODE_NAME=$(ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" "hostname")
for i in {1..10}; do
  STATUS=$(ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$CLUSTER_SSH_KEY" "root@${NODES[s1]}" "kubectl get node ${NODE_NAME} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || echo "Unknown")
  if [[ "${STATUS}" == "True" ]]; then break; fi
  echo -e "${YELLOW}  Узел ${NODE_NAME} ещё не в состоянии Ready, попытка $i...${NC}"
  [ "$i" -eq 10 ] && echo -e "${RED}  Узел ${NODE_NAME} не готов, установка прервана${NC}" && exit 1
  sleep 10
done

echo -e "${GREEN}  Настраиваем окружение на мастер-узле${NC}"
KUBE_CONFIG="/root/.kube/${PREFIX_CONFIG}_Config.yaml"
ln -sf "$KUBE_CONFIG" /root/.kube/config
grep -q "KUBECONFIG=" /root/.bashrc || echo "export KUBECONFIG=$KUBE_CONFIG" >> /root/.bashrc
grep -q "rke2/bin" /root/.bashrc || echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> /root/.bashrc
export KUBECONFIG="$KUBE_CONFIG"
export PATH="$PATH:/var/lib/rancher/rke2/bin"

echo -e "${GREEN}Первый сервер запущен${NC}"; echo -e "${GREEN}${NC}"