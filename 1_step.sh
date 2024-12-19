#!/bin/bash
set -e  # Прекращение выполнения при любой ошибке

# Kube VIP
KVVERSION="v0.8.7"
vip="192.168.5.20"
kube_vip_url="https://raw.githubusercontent.com/Oleg-Perevyshin/Kubernetes/refs/heads/main/deploy/kube-vip"

# Сетевой интерфейс
interface="ens18"

# Имя пользователя и пароль на удаленных машинах
user="poe"
password="MCMega2005!"

# Переменная для ssh сертификата
certName="id_rsa_claster"

# IP адреса машин кластера (управляющая, серверы, агенты)
rke2m=192.168.5.10
rke2s1=192.168.5.11
rke2s2=192.168.5.12
rke2s3=192.168.5.13
rke2a1=192.168.5.14
rke2a2=192.168.5.15

# Общий массив элементов кластера
allclasteritems=("$rke2s1" "$rke2s2" "$rke2s3" "$rke2a1" "$rke2a2")

# Массив серверов
allservers=("$rke2s1" "$rke2s2" "$rke2s3")

####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mЭтап 1: Подготовка для установки кластера RKE2\033[0m"
####################################################################################################################
# Проверка доступности всех узлов
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32m  Проверка доступности узлов\033[0m"
for node in "${allclasteritems[@]}"; do
  ping -c 1 -W 1 "$node" > /dev/null || {
    echo -e "\033[31m    Узел $node недоступен, установка прервана\033[0m"; exit 1;
  }
done
echo -e "\033[32m  Все узлы кластера доступны\033[0m"
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32m  Синхронизация времени на управляющей машине\033[0m"
sudo timedatectl set-ntp off || {
  echo -e "\033[31m    Ошибка при отключении NTP, установка прервана\033[0m"; exit 1;
}
sudo timedatectl set-ntp on || {
  echo -e "\033[31m    Ошибка при включении NTP, установка прервана\033[0m"; exit 1;
}
echo -e "\033[32m  Синхронизация выполнена\033[0m"
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32m  Проверяем конфигурационный файл SSH\033[0m"
[ -f "$HOME/.ssh/config" ] || {
  touch "$HOME/.ssh/config" && chmod 600 "$HOME/.ssh/config"
}
if grep -q "StrictHostKeyChecking yes" "$HOME/.ssh/config"; then
  sed -i 's/StrictHostKeyChecking yes/StrictHostKeyChecking no/' "$HOME/.ssh/config" && \
  echo -e "\033[32m  Заменено 'StrictHostKeyChecking yes' на 'StrictHostKeyChecking no'\033[0m"
else
  grep -q "StrictHostKeyChecking no" "$HOME/.ssh/config" || {
    echo "StrictHostKeyChecking no" >> "$HOME/.ssh/config" && \
    echo -e "\033[32m  Добавлено 'StrictHostKeyChecking no' в конфигурацию SSH\033[0m"
  }
fi
echo -e "\033[32m  Проверка выполнена\033[0m"
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32m  Проверяем KUBECTL\033[0m"
command -v kubectl &> /dev/null && {
  current_version=$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $3}' | sed 's/v//')
} || {
  echo -e "\033[31m  Не установлен, выполняется установка...\033[0m"
  current_version=""
}
latest_version=$(curl -L -s https://dl.k8s.io/release/stable.txt | sed 's/v//')
if [ -n "$current_version" ]; then
  if [ "$current_version" != "$latest_version" ]; then
    sudo rm -f /usr/local/bin/kubectl
    curl -LO "https://dl.k8s.io/release/v$latest_version/bin/linux/amd64/kubectl" && \
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && \
    echo -e "\033[32m  KUBECTL успешно обновлен (версия: v$latest_version)\033[0m" || \
    echo -e "\033[31m  Ошибка при обновлении KUBECTL\033[0m"
  else
    echo -e "\033[32m  Обновление не требуется\033[0m"
  fi
else
  sudo rm -f /usr/local/bin/kubectl
  curl -LO "https://dl.k8s.io/release/v$latest_version/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  echo -e "\033[32m  KUBECTL успешно установлен (версия: v$latest_version)\033[0m"
fi
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32m  Добавляем SSH ключ ко всем узлам кластера\033[0m"
certPath="$HOME/.ssh/$certName"
# Проверим, существует ли SSH-ключ
[ -f "$certPath" ] || {
  echo -e "\033[31m  SSH-ключ не найден, создайте его с помощью команды:\033[0m"
  echo -e "\033[31m  ssh-keygen -t rsa -b 4096 -f /home/poe/.ssh/id_rsa_claster -C 'rke2_claster_manager';\033[0m"
  exit 1
}
for host in "${allclasteritems[@]}"; do
  sshpass -p "$password" ssh-copy-id -o StrictHostKeyChecking=no -i "$certPath" "$user@$host" > /dev/null 2>&1 || {
    echo -e "\033[31m    Ошибка при передаче ключа на $host\033[0m"; exit 1;
  }
done
echo -e "\033[32m  SSH ключи добавлены\033[0m"
echo -e "\033[32m--------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mЭтап 2: Kube VIP (Virtual IP)\033[0m"
####################################################################################################################
# Создаем директорию для манифестов
echo -e "\033[32m  Создаем директорию для манифестов: /var/lib/rancher/rke2/server/manifests\033[0m"
sudo mkdir -p "/var/lib/rancher/rke2/server/manifests" || {
  echo -e "\033[31m  Ошибка при создании директории для манифестов, установка прервана\033[0m"; exit 1;
}

kube_vip_dest="/var/lib/rancher/rke2/server/manifests/kube-vip.yaml"

# Загружаем файл и производим замену переменных
echo -e "\033[32m  Загружаем файл $kube_vip_url и производим замену переменных\033[0m"
curl -s "$kube_vip_url" | sed 's/$interface/'"$interface"'/g; s/$vip/'"$vip"'/g' | sudo tee "$HOME/kube-vip.yaml" > /dev/null || {
  echo -e "\033[31m  Ошибка при загрузке kube-vip, установка прервана\033[0m"; exit 1;
}

# Перемещаем kube-vip.yaml в /var/lib/rancher/rke2/server/manifests/
echo -e "\033[32m  Перемещаем kube-vip.yaml в /var/lib/rancher/rke2/server/manifests\033[0m"
sudo mv "$HOME/kube-vip.yaml" "$kube_vip_dest" || {
  echo -e "\033[31m  Ошибка при перемещении kube-vip.yaml, установка прервана\033[0m"; exit 1;
}

# Заменяем все записи k3s на rke2 в файле /var/lib/rancher/rke2/server/manifests/kube-vip.yaml
echo -e "\033[32m  Заменяем все записи k3s на rke2 в файле /var/lib/rancher/rke2/server/manifests/kube-vip.yaml\033[0m"
sudo sed -i 's/k3s/rke2/g' "$kube_vip_dest" || {
  echo -e "\033[31m  Ошибка при редактировании kube-vip.yaml, установка прервана\033[0m"; exit 1;
}

# Копируем $kube_vip_dest обратно в домашнюю директорию
echo -e "\033[32m  Копируем kube-vip.yaml обратно в домашнюю директорию\033[0m"
sudo cp "$kube_vip_dest" "$HOME/kube-vip.yaml" || {
  echo -e "\033[31m  Ошибка при копировании kube-vip.yaml, установка прервана\033[0m"; exit 1;
}

# Меняем владельца на текущего пользователя
echo -e "\033[32m  Меняем владельца kube-vip.yaml на $user\033[0m"
sudo chown "$user:$user" "kube-vip.yaml" || {
  echo -e "\033[31m  Ошибка при изменении владельца kube-vip.yaml, установка прервана\033[0m"; exit 1;
}

# Создаем директорию для kubectl
echo -e "\033[32m  Создаем директорию $HOME/.kube\033[0m"
mkdir -p "$HOME/.kube" || {
  echo -e "\033[31m  Ошибка при создании директории $HOME/.kube, установка прервана\033[0m"; exit 1;
}

# Создаем файл настроек
echo -e "\033[32m  Создаем файл $HOME/config.yaml\033[0m"
cat <<EOF | sudo tee "$HOME/config.yaml" > /dev/null
tls-san:
  - $vip
  - $rke2m
  - $rke2s1
  - $rke2s2
  - $rke2s3
write-kubeconfig-mode: 0644
disable:
  - rke2-ingress-nginx
EOF

# Создаем директорию /etc/rancher/rke2/
echo -e "\033[32m  Создаем директорию $HOME/.kube\033[0m"
sudo mkdir -p "/etc/rancher/rke2" || {
  echo -e "\033[31m  Ошибка при создании директории /etc/rancher/rke2, установка прервана\033[0m"; exit 1;
}

# Копируем файл в директорию /etc/rancher/rke2/
sudo cp "$HOME/config.yaml" "/etc/rancher/rke2/config.yaml" || {
  echo -e "\033[31m  Ошибка при копировании файла $HOME/config.yaml в /etc/rancher/rke2/config.yaml\033[0m"; exit 1;
}

# Обновляем пути с rke2-binaries
grep -q "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" "$HOME/.bashrc" || {
  echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> "$HOME/.bashrc"
}
grep -q "export PATH=\${PATH}:/var/lib/rancher/rke2/bin" "$HOME/.bashrc" || {
  echo 'export PATH=${PATH}:/var/lib/rancher/rke2/bin' >> "$HOME/.bashrc"
}
grep -q "alias k=kubectl" "$HOME/.bashrc" || {
  echo 'alias k=kubectl' >> "$HOME/.bashrc"
}
source "$HOME/.bashrc"

# Копируем kube-vip.yaml и сертификаты на все серверы
echo -e "\033[32m  Копируем файлы: kube-vip.yaml, config.yaml и сертификаты на серверы\033[0m"
for newnode in "${allservers[@]}"; do
  scp -i "$HOME/.ssh/$certName" "$HOME/kube-vip.yaml" "$user@$newnode:$HOME/kube-vip.yaml" > /dev/null 2>&1 || {
    echo -e "\033[31m  Ошибка при копировании kube-vip.yaml на $newnode\033[0m"; exit 1;
  }
  scp -i "$HOME/.ssh/$certName" "$HOME/config.yaml" "$user@$newnode:$HOME/config.yaml" > /dev/null 2>&1 || {
    echo -e "\033[31m  Ошибка при копировании config.yaml на $newnode\033[0m"; exit 1;
  }
  scp -i "$HOME/.ssh/$certName" "$HOME/.ssh/$certName" "$user@$newnode:$HOME/.ssh" > /dev/null 2>&1 || {
    echo -e "\033[31m  Ошибка при копировании сертификата $certName на $newnode\033[0m"; exit 1;
  }
  scp -i "$HOME/.ssh/$certName" "$HOME/.ssh/$certName.pub" "$user@$newnode:$HOME/.ssh" > /dev/null 2>&1 || {
    echo -e "\033[31m  Ошибка при копировании сертификата $certName.pub на $newnode\033[0m"; exit 1;
  }
done
echo -e "\033[32m  Копирование завершено\033[0m"
echo -e "\033[32m--------------------------------\033[0m"
