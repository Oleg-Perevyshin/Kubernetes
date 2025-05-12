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
echo -e "${GREEN}ЭТАП 1: Настройка сервера RKE2${NC}"
echo -e "${GREEN}[1/11] Проверяем доступность сервера${NC}"
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
  echo -e "${GREEN}[2/11] Проверяем kubectl${NC}"
  if command -v kubectl &>/dev/null; then
    CURRENT_VERSION=\$(kubectl version --client | grep 'Client Version' | awk '{print \$3}' | sed 's/v//')
  else
    CURRENT_VERSION=""
    echo -e "${YELLOW}    kubectl не установлен, выполняется установка${NC}"
  fi
  LATEST_VERSION=\$(curl -L -s https://cdn.dl.k8s.io/release/stable.txt | sed 's/v//')
  if [ -n "\$CURRENT_VERSION" ]; then
    if [ "\$CURRENT_VERSION" != "\$LATEST_VERSION" ]; then
      sudo rm -f /usr/local/bin/kubectl
      curl -LO "https://dl.k8s.io/release/v\$LATEST_VERSION/bin/linux/amd64/kubectl"
      sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    fi
  else
    curl -LO "https://dl.k8s.io/release/v\$LATEST_VERSION/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  fi
  CURRENT_VERSION=\$(kubectl version --client | grep 'Client Version' | awk '{print \$3}' | sed 's/v//')
  echo -e "${GREEN}  ✓ kubectl v\$CURRENT_VERSION установлен${NC}"
  #
  #
  echo -e "${GREEN}[3/11] Готовим директорию .kube${NC}"
  HOME_DIR="/home/poe"
  mkdir -p "\$HOME_DIR/.kube" || {
    echo -e "${RED}  Ошибка создания директории \$HOME_DIR/.kube, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Директория .kube подготовлена${NC}"
  #
  #
  echo -e "${GREEN}[4/11] Устанавливаем Helm${NC}"
  curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка установки Helm, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Helm установлен${NC}"
  #
  #
  echo -e "${GREEN}[5/11] Устанавливаем RKE2 сервер${NC}"
  timedatectl set-ntp off; timedatectl set-ntp on; echo -e "${GREEN}    Синхронизация времени выполнена${NC}"
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh - || {
    echo -e "${RED}  Ошибка при установке RKE2, установка прервана${NC}"
    exit 1
  }
  echo -e "${GREEN}  ✓ Сервер RKE2 установлен${NC}"
  echo -e "${GREEN}[6/11] Запускаем сервис rke2-server${NC}"
  mkdir -p /etc/rancher/rke2
  systemctl enable --now rke2-server.service
  systemctl start rke2-server.service
  sleep 5
  if ! systemctl is-active --quiet rke2-server.service; then
    echo -e "${RED}  Сервис rke2-server не запустился, установка прервана${NC}"
    exit 1
  fi
  echo -e "${GREEN}  ✓ Сервис RKE2 успешно запущен${NC}"
  #
  #
  echo -e "${GREEN}[7/11] Работаем с переменными окружения на сервере${NC}"
  if ! grep -q "export KUBECONFIG=" \$HOME/.bashrc; then
    echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> \$HOME/.bashrc
    echo -e "${GREEN}  ✓ KUBECONFIG добавлена в .bashrc на сервере${NC}"
  else
    echo -e "${YELLOW}  KUBECONFIG уже существует в .bashrc на сервере${NC}"
  fi
  #
  #
  echo -e "${GREEN}[8/11] Создаем файлы настроек кластера в папке .kube${NC}"
  CONFIG_FILE="\$HOME_DIR/.kube/${PREFIX_CONFIG}_config"
  cat /etc/rancher/rke2/rke2.yaml > "\$HOME_DIR/.kube/${PREFIX_CONFIG}_rke2.yaml"
  cat /var/lib/rancher/rke2/server/token > "\$HOME_DIR/.kube/${PREFIX_CONFIG}_token"
  sed "s/127.0.0.1/${NODES[server]}/g" "\$HOME_DIR/.kube/${PREFIX_CONFIG}_rke2.yaml" | sudo tee "\$CONFIG_FILE" >/dev/null
  chown "\$(id -u):\$(id -g)" "\$CONFIG_FILE"
  echo -e "${GREEN}  ✓ Настройки кластера сохранены в папке .kube${NC}"
EOF
#
#
echo -e "${GREEN}[9/11] Копируем токен и конфигурацию на текущую машину${NC}"
ssh -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" "sudo cat /var/lib/rancher/rke2/server/token" >"$HOME/.kube/${PREFIX_CONFIG}_token" || {
  echo -e "${RED}  Ошибка при копировании токена с ${NODES[server]}, установка прервана${NC}"
  exit 1
}
ssh -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" "sudo cat /etc/rancher/rke2/rke2.yaml" >"$HOME/.kube/${PREFIX_CONFIG}_rke2.yaml" || {
  echo -e "${RED}  Ошибка при копировании конфигурации с ${NODES[server]}, установка прервана${NC}"
  exit 1
}
echo -e "${GREEN}  ✓ Копирование завершено, файлы сохранены в папке .kube${NC}"
#
#
echo -e "${GREEN}[10/11] Задаем файл конфигурации для kubectl и обновляем конфигурацию (заменяем IP-адрес)${NC}"
CONFIG_FILE="$HOME/.kube/${PREFIX_CONFIG}_config"
sudo sed "s/127.0.0.1/${NODES[server]}/g" "$HOME/.kube/${PREFIX_CONFIG}_rke2.yaml" | sudo tee "$CONFIG_FILE" >/dev/null
sudo chown "$(id -u):$(id -g)" "$CONFIG_FILE"
echo -e "${GREEN}  ✓ Файл для подключения к кластеру успешно создан и сохранен ${CONFIG_FILE}${NC}"
#
#
echo -e "${GREEN}[11/11] Устанавливаем переменную окружения KUBECONFIG и добавляем в .bashrc на машине управления${NC}"
if ! grep -q "export KUBECONFIG=" "$HOME/.bashrc"; then
  echo "export KUBECONFIG=\"$CONFIG_FILE\"" >>"$HOME/.bashrc"
  echo -e "${GREEN}  ✓ Переменная окружения KUBECONFIG добавлена в .bashrc на машине управления${NC}"
else
  echo -e "${YELLOW}  Переменная окружения KUBECONFIG уже существует в .bashrc на машине управления${NC}"
fi

echo -e "${GREEN}${NC}"
echo -e "${GREEN}Cервер кластера RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
