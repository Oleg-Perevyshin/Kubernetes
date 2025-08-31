#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 4-HA-Cluster.sh;

# Конфигурация кластера
declare -A NODES=(
  [s1]="192.168.5.31" [s2]="192.168.5.32" [s3]="192.168.5.33"
  [a1]="192.168.5.34" [a2]="192.168.5.35" [a3]="192.168.5.36"
  [vip]="192.168.5.40"
)
ORDERED_NODES=("${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}" "${NODES[vip]}")
CLUSTER_SSH_KEY="/root/.ssh/id_rsa_cluster"
PREFIX_CONFIG="HomeLab"
set -euo pipefail
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' NC='\033[0m'
TARGET_SEVER=true
TARGET_AGENT=true

#############################################
echo -e "${GREEN}ЭТАП 4: Настройка остальных узлов кластера RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c1 -W1 "$node_ip" &>/dev/null || { echo -e "${RED}    ✗ Узел $node_ip недоступен, установка прервана${NC}"; exit 1; }
done
[ ! -f "$CLUSTER_SSH_KEY" ] && echo -e "${RED}  ✗ SSH ключ $CLUSTER_SSH_KEY не найден, установка прервана${NC}" && exit 1
[ ! -s "/root/.kube/${PREFIX_CONFIG}_Token" ] && echo -e "${RED}  ✗ Файл токена отсутствует или пустой, установка прервана${NC}" && exit 1
TOKEN=$(cat "/root/.kube/${PREFIX_CONFIG}_Token")

for node_ip in "${ORDERED_NODES[@]}"; do
  node_name=""
  for name in "${!NODES[@]}"; do [[ "${NODES[$name]}" == "$node_ip" ]] && node_name="$name" && break; done
  [[ -z "$node_name" ]] && echo -e "${RED}  Не найдено имя для IP ${node_ip}, установка прервана${NC}" && exit 1

  if [[ "${node_name}" == s* && "${node_name}" != "s1" && ${TARGET_SEVER} == true ]]; then
    echo -e "${GREEN}${NC}"; echo -e "${GREEN}  Настраиваем сервер ${node_ip}${NC}";
    ssh -i "$CLUSTER_SSH_KEY" "root@${node_ip}" bash -c "bash -s" <<SETUP_SERVER
      set -euo pipefail
      export PATH=\$PATH:/usr/local/bin

      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      mkdir -p "/var/lib/rancher/rke2/server/manifests/" >/dev/null
      install -D -m 600 /dev/null "/etc/rancher/rke2/config.yaml" >/dev/null
      cat <<CONFIG > /etc/rancher/rke2/config.yaml
server: https://${NODES[vip]}:9345
token: ${TOKEN}
node-ip: "${node_ip}"
tls-san: [${NODES[vip]}, ${NODES[s1]}, ${NODES[s2]}, ${NODES[s3]}]
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
        [ "\$i" -eq 30 ] && echo -e "${RED}    ✗ Файл конфигурации не создан, установка прервана${NC}" && exit 1
        sleep 10
      done
      grep -q "export KUBECONFIG=" "/root/.bashrc" ||echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> "/root/.bashrc"
      grep -q "export PATH=.*rancher/rke2/bin" "/root/.bashrc" || echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' >> "/root/.bashrc"
      ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
      echo -e "${GREEN}  Сервер настроен${NC}"
SETUP_SERVER
  fi

  if [[ "${node_name}" == a* && ${TARGET_AGENT} == true ]]; then
    echo -e "${GREEN}${NC}"; echo -e "${GREEN}  Настраиваем агент ${node_ip}${NC}";
    ssh -i "$CLUSTER_SSH_KEY" "root@${node_ip}" bash -c "bash -s" <<SETUP_AGENT
      set -euo pipefail
      export PATH=\$PATH:/usr/local/bin

      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      install -D -m 600 /dev/null "/etc/rancher/rke2/config.yaml" && cat > "/etc/rancher/rke2/config.yaml" <<CONFIG
server: https://${NODES[vip]}:9345
token: ${TOKEN}
node-ip: "${node_ip}"
tls-san: [${NODES[vip]}, ${NODES[s1]}, ${NODES[s2]}, ${NODES[s3]}]
node-label: [worker=true, longhorn=true]
write-kubeconfig-mode: 600
CONFIG
      tar xzf /root/rke2.linux-amd64.tar.gz -C /usr/local
      ln -sf /usr/local/bin/rke2 /usr/local/bin/rke2-agent
      cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/
      systemctl daemon-reload
      systemctl enable --now rke2-agent.service
      for i in {1..30}; do
        systemctl is-active --quiet rke2-agent.service && break
        [ "\$i" -eq 30 ] && echo -e "${RED}    ✗ Агент не запустился, установка прервана${NC}" && exit 1
        sleep 10
      done
      echo -e "${GREEN}  Агент настроен${NC}"
SETUP_AGENT
  fi
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}Кластер RKE2 настроен${NC}"; echo -e "${GREEN}${NC}";
