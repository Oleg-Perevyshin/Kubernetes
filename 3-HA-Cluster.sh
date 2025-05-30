#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 3-HA-Cluster.sh;

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
ORDERED_NODES=("${NODES[vip]}" "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}")

# Имя пользователя, имя файла SSH сертификата и набор адресов
CERT_NAME="id_rsa_cluster"
PREFIX_CONFIG="Home"

# Определяем целевые узлы для настройки
TARGET_SEVER=true
TARGET_AGENT=true

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

echo -e "${GREEN}ЭТАП 3: Настройка остальных узлов кластера RKE2${NC}"
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}  Проверяем доступность узлов${NC}"
for node_ip in "${ORDERED_NODES[@]}"; do
  ping -c 1 -W 1 "${node_ip}" >/dev/null || {
    echo -e "${RED}    ✗ Узел ${node_ip} недоступен, установка прервана${NC}"
    exit 1
  }
done

echo -e "${GREEN}  Проверяем сертификат и получаем токен доступа${NC}"
if [ ! -f "/root/.ssh/$CERT_NAME" ]; then
  echo -e "${RED}  ✗ SSH ключ $CERT_NAME не найден, установка прервана${NC}"
  exit 1
fi
TOKEN=$(cat "/root/.kube/${PREFIX_CONFIG}_Cluster_Token")

for node_ip in "${ORDERED_NODES[@]}"; do
  for name in "${!NODES[@]}"; do
    if [[ "${NODES[$name]}" == "${node_ip}" ]]; then
      node_name="${name}"
      break
    fi
  done
  if [[ -z "${node_name}" ]]; then
    echo -e "${RED}  Не найдено имя для IP ${node_ip}, установка прервана${NC}"
    exit 1
  fi

  if [[ "${node_name}" == s* && "${node_name}" != "s1" && ${TARGET_SEVER} == true ]]; then
    echo -e "${GREEN}${NC}"
    echo -e "${GREEN}  Настраиваем сервер ${node_ip}${NC}"

    ssh -i "/root/.ssh/$CERT_NAME" "root@${node_ip}" bash -c "bash -s" <<SERVER
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      export PATH=$PATH:/usr/local/bin

      echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
      mkdir -p "/var/lib/rancher/rke2/server/manifests/" >/dev/null
      install -D -m 600 /dev/null "/etc/rancher/rke2/config.yaml" && cat > "/etc/rancher/rke2/config.yaml" <<CONFIG_SERVER
server: https://${NODES[vip]}:9345
token: ${TOKEN}
node-ip: "${node_ip}"
tls-san: [${NODES[vip]}, ${NODES[s1]}, ${NODES[s2]}, ${NODES[s3]}]
write-kubeconfig-mode: 600
etcd-expose-metrics: true
CONFIG_SERVER

      tar xzf /root/rke2.linux-amd64.tar.gz -C /usr/local
      ln -sf /usr/local/bin/rke2 /usr/local/bin/rke2-server
      cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/
      systemctl daemon-reload
      systemctl enable --now rke2-server.service
      for count in {1..30}; do
        if [ -f /etc/rancher/rke2/rke2.yaml ]; then
          break
        elif [ "\$count" -eq 30 ]; then
          echo -e "${RED}    ✗ Файл конфигурации не создан, установка прервана${NC}"
          exit 1
        else
          sleep 10
        fi
      done
      rm -f "/root/rke2.linux-amd64.tar.gz"

      echo -e "${GREEN}  Настраиваем окружение${NC}"
      grep -q "export KUBECONFIG=" "/root/.bashrc" ||echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> "/root/.bashrc"
      grep -q "export PATH=.*rancher/rke2/bin" "/root/.bashrc" || echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' >> "/root/.bashrc"
      ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
SERVER
  fi

  if [[ "${node_name}" == a* && ${TARGET_AGENT} == true ]]; then
  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Настраиваем агент ${node_ip}${NC}"
  ssh -i "/root/.ssh/$CERT_NAME" "root@${node_ip}" bash -c "bash -s" <<AGENT
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export PATH=$PATH:/usr/local/bin

    echo -e "${GREEN}  Устанавливаем и запускаем RKE2, ждите...${NC}"
    install -D -m 600 /dev/null "/etc/rancher/rke2/config.yaml" && cat > "/etc/rancher/rke2/config.yaml" <<CONFIG_AGENT
server: https://${NODES[vip]}:9345
token: ${TOKEN}
node-ip: "${node_ip}"
tls-san: [${NODES[vip]}, ${NODES[s1]}, ${NODES[s2]}, ${NODES[s3]}]
node-label: [worker=true, longhorn=true]
write-kubeconfig-mode: 600
CONFIG_AGENT

    tar xzf /root/rke2.linux-amd64.tar.gz -C /usr/local
    ln -sf /usr/local/bin/rke2 /usr/local/bin/rke2-agent
    cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now rke2-agent.service
    for count in {1..30}; do
      if systemctl is-active --quiet rke2-agent.service; then
        break
      elif [ "\$count" -eq 30 ]; then
        echo -e "${RED}    ✗ Агент не запустился, установка прервана${NC}"
        exit 1
      else
        sleep 10
      fi
    done
    rm -f "/root/rke2.linux-amd64.tar.gz"
AGENT
  fi
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Кластер RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
