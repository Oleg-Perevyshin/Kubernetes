#!/bin/bash
# Сделать файл исполняемым на машине мастера chmod +x 0-ResetAll.sh;

# Определяем машины кластера
declare -A NODES=(
  [s1]="192.168.5.11"
  [s2]="192.168.5.12"
  [s3]="192.168.5.13"
  [a1]="192.168.5.14"
  [a2]="192.168.5.15"
  [a3]="192.168.5.16"
)

CERT_NAME="id_rsa_cluster"

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'


[ "$(id -u)" -eq 0 ] || {
  echo -e "${RED}Скрипт должен запускаться от root, работа скрипта прекращена${NC}" >&2
  exit 1
}

echo -e "${GREEN}Полный сброс кластера${NC}"

echo -e "${GREEN}  Удаляем папку для хранения настроек${NC}"
rm -rf "/root/.kube" 2>/dev/null || true

for node_ip in "${NODES[s1]}" "${NODES[s2]}" "${NODES[s3]}" "${NODES[a1]}" "${NODES[a2]}" "${NODES[a3]}"; do
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

  echo -e "${GREEN}${NC}"
  echo -e "${GREEN}  Обрабатываем узел ${node_ip}${NC}"
  if ! ping -c 1 -W 1 "${node_ip}" &>/dev/null; then
    echo -e "${RED}    ✗ Узел $ip недоступен, работа скрипта прекращена${NC}"
    exit 1
  fi

  ssh -i "/root/.ssh/$CERT_NAME" "root@${node_ip}" bash -c "bash -s" <<RESET_CLUSTER
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export PATH=$PATH:/usr/local/bin
    NODE_NAME="${node_name}"
    NODE_IP="${node_ip}"

    [ -f /usr/local/bin/rke2-uninstall.sh ] && /usr/local/bin/rke2-uninstall.sh >/dev/null || true
    [ -f /usr/local/bin/rke2-killall.sh ] && /usr/local/bin/rke2-killall.sh >/dev/null || true

    if [[ "\${NODE_NAME}" == s* ]]; then
      echo -e "${GREEN}  Очищаем сервер${NC}"
      rm -f /usr/local/bin/helm >/dev/null
      rm -rf /root/.{helm,config/helm,cache/helm,.local/share/helm} >/dev/null
      [ "\${NODE_NAME}" == "s1" ] && command -v docker &>/dev/null && {
        echo -e "${GREEN}  Очищаем Docker...${NC}"
        systemctl restart docker &>/dev/null || true
        docker system prune -a -f &>/dev/null || true
      }
    fi

    echo -e "${GREEN}  Перезагружаем узел...${NC}"
    nohup reboot &>/dev/null & exit
RESET_CLUSTER
done
# ----------------------------------------------------------------------------------------------- #
echo -e "${GREEN}${NC}"
echo -e "${GREEN}Все узла сброшены до первоначального состояния${NC}"
echo -e "${GREEN}${NC}"
