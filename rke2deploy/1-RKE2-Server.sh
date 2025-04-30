#!/bin/bash
# Вызвываем chmod +x 1-RKE2-Server.sh; из командной строки чтоб сделать файл исполняемым
set -e # Прекращение выполнения при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Имя пользователя и сертификат доступа
USER="poe"
CERT_NAME="id_rsa_rke2m"

# Машины кластера
declare -A NODES=([server]="192.168.83.21" [agent_1]="192.168.83.22" [agent_2]="192.168.83.23")
# declare -A NODES=([server]="192.168.5.21" [agent_1]="192.168.5.22" [agent_2]="192.168.5.23")

####################################################################################################
echo -e "${GREEN}${NC}"
echo -e "${GREEN}ЭТАП 1: Настройка сервера${NC}"
# shellcheck disable=SC2087
ssh -q -t -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" sudo bash <<EOF
  set -e;
  HOME_DIR="/home/poe";

  # Проверяем наличие kubectl
  if ! command -v kubectl &>/dev/null; then
    echo -e "${YELLOW}  kubectl не установлен, выполняется установка${NC}";
    LATEST_VERSION=\$(curl -L -s https://cdn.dl.k8s.io/release/stable.txt);
    echo -e "${GREEN}  Скачиваем kubectl версии \$LATEST_VERSION${NC}";
    curl -LO "https://dl.k8s.io/release/\$LATEST_VERSION/bin/linux/amd64/kubectl" -o "\$HOME_DIR/kubectl" >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка скачивания kubectl${NC}"; exit 1;
    }
    sudo chown poe:poe "\$HOME_DIR/kubectl"
    sudo chmod +x "\$HOME_DIR/kubectl"
    sudo install -m 0755 "\$HOME_DIR/kubectl" /usr/local/bin/kubectl >/dev/null 2>&1 || {
      echo -e "${RED}  Ошибка установки kubectl${NC}"; exit 1;
    }
    echo -e "${GREEN}  kubectl \$LATEST_VERSION установлен${NC}";
  else
    echo -e "${GREEN}  kubectl установлен${NC}";
  fi

  # Удаляем директорию .kube, если она существует, и создаем новую
  if [ -d "\$HOME_DIR/.kube" ]; then
    rm -rf "\$HOME_DIR/.kube" || { echo -e "${RED}  Ошибка при удалении директории \$HOME_DIR/.kube, установка прервана${NC}"; exit 1; }
  fi
  mkdir -p "\$HOME_DIR/.kube" || { echo -e "${RED}  Ошибка при создании директории \$HOME_DIR/.kube, установка прервана${NC}"; exit 1; }
  echo -e "${GREEN}  Директория \$HOME_DIR/.kube подготовлена${NC}";

  # Устанавливаем Helm
  curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1 || {
    echo -e "${RED}  Ошибка установки Helm, установка прервана${NC}"; exit 1;
  }
  echo -e "${GREEN}  Helm установлен${NC}";

  # Устанавливаем RKE2 сервер
  timedatectl set-ntp off; timedatectl set-ntp on; echo -e "${GREEN}  Синхронизация времени выполнена${NC}";
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="server" sh - || { echo -e "${RED}  Ошибка при установке RKE2, установка прервана${NC}"; exit 1; }
  echo -e "${GREEN}  RKE2 успешно установлен${NC}";

  # Ожидаем запуска службы RKE2 и проверяем статус
  mkdir -p /etc/rancher/rke2;
  systemctl enable --now rke2-server.service;
  sleep 5;
  if ! systemctl is-active --quiet rke2-server.service; then
    echo -e "${RED}  Сервис rke2-server не запустился, установка прервана${NC}"; exit 1;
  fi

  # Создаем символическую ссылку на kubectl
  KUBECTL_PATH="\$HOME_DIR/kubectl";
  if [ -f "\$KUBECTL_PATH" ]; then
    if [ -e /usr/local/bin/kubectl ]; then
      sudo rm /usr/local/bin/kubectl; echo -e "${YELLOW}  Старая символическая ссылка на kubectl удалена${NC}";
    fi
    sudo ln -s "\$KUBECTL_PATH" /usr/local/bin/kubectl; echo -e "${GREEN}  Символическая ссылка на kubectl создана${NC}";
  else
    echo -e "${RED}  kubectl не найден в домашнем каталоге: \$KUBECTL_PATH, установка прервана${NC}"; exit 1;
  fi

  # Обновление переменных окружения
  if ! grep -q "export KUBECONFIG=" \$HOME/.bashrc; then
    echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> \$HOME/.bashrc;
    echo -e "${GREEN}  Переменная окружения KUBECONFIG добавлена в .bashrc${NC}";
  else
    echo -e "${YELLOW}  Переменная окружения KUBECONFIG уже существует в .bashrc${NC}";
  fi

  # Задаем файл конфигурации для kubectl и обновляем конфигурацию (заменяем IP-адрес)
  CONFIG_FILE="\$HOME_DIR/.kube/config";
  cat /etc/rancher/rke2/rke2.yaml > "\$HOME_DIR/.kube/rke2.yaml";
  cat /var/lib/rancher/rke2/server/token > "\$HOME_DIR/.kube/token";
  sed "s/127.0.0.1/${NODES[server]}/g" "\$HOME_DIR/.kube/rke2.yaml" | sudo tee "\$CONFIG_FILE" >/dev/null;
  chown "\$(id -u):\$(id -g)" "\$CONFIG_FILE";
EOF

# Копируем токен и конфигурацию на вспомогательную машину управления
ssh -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" "sudo cat /var/lib/rancher/rke2/server/token" >"$HOME/.kube/token" || {
  echo -e "${RED}  Ошибка при копировании токена с ${NODES[server]}, установка прервана${NC}"
  exit 1
}
ssh -i "$HOME/.ssh/$CERT_NAME" "$USER@${NODES[server]}" "sudo cat /etc/rancher/rke2/rke2.yaml" >"$HOME/.kube/rke2.yaml" || {
  echo -e "${RED}  Ошибка при копировании конфигурации с ${NODES[server]}, установка прервана${NC}"
  exit 1
}

# Задаем файл конфигурации для kubectl и обновляем конфигурацию (заменяем IP-адрес)
CONFIG_FILE="$HOME/.kube/config"
sudo sed "s/127.0.0.1/${NODES[server]}/g" "$HOME/.kube/rke2.yaml" | sudo tee "$CONFIG_FILE" >/dev/null
sudo chown "$(id -u):$(id -g)" "$CONFIG_FILE"

# Устанавливаем переменную окружения KUBECONFIG и добавляем в .bashrc
echo "export KUBECONFIG=\"$CONFIG_FILE\"" >>~/.bashrc
echo -e "${GREEN}Cервер кластера RKE2 настроен${NC}"
echo -e "${GREEN}${NC}"
