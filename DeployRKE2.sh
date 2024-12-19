# DeployRKE2.sh
#!/bin/bash
set -e  # Прекращение выполнения при любой ошибке

# Kube VIP
kvip_ver="v0.8.7"
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

# Диапазон адресов балансировщика нагрузки
lbrange="192.168.5.21-192.168.5.39"

# Общий массив элементов кластера
allclasteritems=("$rke2s1" "$rke2s2" "$rke2s3" "$rke2a1" "$rke2a2")

# Массив серверов
allservers=("$rke2s1" "$rke2s2" "$rke2s3")
allserversnorke2s1=("$rke2s2" "$rke2s3")

# Массив агентов
allagents=("$rke2a1" "$rke2a2")

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
echo -e "\033[32m  Синхронизация времени выполнена\033[0m"
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
curl -s "$kube_vip_url" | \
sed 's/$interface/'"$interface"'/g; s/$vip/'"$vip"'/g; s/\$kvip_ver/'"$kvip_ver"'/g' | \
sudo tee "$HOME/kube-vip.yaml" > /dev/null || {
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


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
# Подключаемся к rke2s1, устанавливаем RKE2, копируем токен обратно на машину администратора
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mЭтап 3: Настройка первого сервера\033[0m"
####################################################################################################################
echo -e "\033[32m  Подключение к $rke2s1 и установка RKE2...\033[0m"
ssh -q -t -i "$HOME/.ssh/$certName" "$user@$rke2s1" sudo su <<EOF
  # Синхронизация времени
  echo -e "\033[32m  Синхронизация времени на сервере $rke2s1\033[0m"
  timedatectl set-ntp off || {
    echo -e "\033[31m    Ошибка при отключении NTP, установка прервана\033[0m"; exit 1;
  }
  timedatectl set-ntp on || {
    echo -e "\033[31m    Ошибка при включении NTP, установка прервана\033[0m"; exit 1;
  }
  echo -e "\033[32m  Синхронизация времени выполнена\033[0m"

  # Создаем необходимые директории
  mkdir -p /var/lib/rancher/rke2/server/manifests
  mkdir -p /etc/rancher/rke2

  # Копирование файлов (удалить в конце)
  cp "/home/$user/kube-vip.yaml" "/var/lib/rancher/rke2/server/manifests/kube-vip.yaml" && {
    echo -e "\033[32m  Файл /home/$user/kube-vip.yaml скопирован\033[0m"
  } || {
    echo -e "\033[31m  Ошибка копирования /home/$user/kube-vip.yaml\033[0m"; exit 1;
  }
  cp "/home/$user/config.yaml" "/etc/rancher/rke2/config.yaml" && {
    echo -e "\033[32m  Файл /home/$user/config.yaml скопирован\033[0m"
  } || {
    echo -e "\033[31m  Ошибка копирования /home/$user/config.yaml\033[0m"; exit 1;
  }

  # Обновляем пути
  {
    grep -q 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' "/home/$user/.bashrc" || echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml'
    grep -q 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin' "/home/$user/.bashrc" || echo 'export PATH=\${PATH}:/var/lib/rancher/rke2/bin'
    grep -q 'alias k=kubectl' "/home/$user/.bashrc" || echo 'alias k=kubectl'
  } >> "/home/$user/.bashrc"

  # Устанавливаем RKE2
  curl -sfL https://get.rke2.io | sh - && echo -e "\033[32m  RKE2 успешно установлен\033[0m" || {
    echo -e "\033[31m  Ошибка при установке RKE2\033[0m"; exit 1;
  }

  # Включаем и запускаем службы RKE2
  systemctl enable rke2-server.service
  systemctl start rke2-server.service
  
  exit
EOF

# Копирование токена и конфигурации
echo -e "\033[32m  Копируем токен и конфигурацию с $rke2s1 на $rke2m...\033[0m"
ssh -i "$HOME/.ssh/$certName" "$user@$rke2s1" "sudo cat /var/lib/rancher/rke2/server/token" > "$HOME/token" && \
echo -e "\033[32m  Токен успешно скопирован с $rke2s1\033[0m" || { \
  echo -e "\033[31m  Ошибка при копировании токена с $rke2s1\033[0m"; exit 1; }

ssh -i "$HOME/.ssh/$certName" "$user@$rke2s1" "sudo cat /etc/rancher/rke2/rke2.yaml" > "$HOME/.kube/rke2.yaml" && \
echo -e "\033[32m  Конфигурация успешно скопирована с $rke2s1\033[0m" || { \
  echo -e "\033[31m  Ошибка при копировании конфигурации с $rke2s1\033[0m"; exit 1; }

# Задаем файл конфигурации для kubectl
config_file="$HOME/.kube/config"

# Обновляем конфигурацию и заменяем IP-адрес
sudo sed "s/127.0.0.1/$rke2s1/g" ~/.kube/rke2.yaml > "$config_file"

# Устанавливаем владельца файла конфигурации
sudo chown "$(id -u):$(id -g)" "$config_file"

# Устанавливаем переменную окружения KUBECONFIG
export KUBECONFIG="$config_file"

# Копируем конфигурацию в RKE2
sudo cp "$config_file" /etc/rancher/rke2/rke2.yaml || {
  echo -e "\033[31m  Ошибка при копировании конфигурации\033[0m"; exit 1;
}
chmod 600 "$config_file"
echo -e "\033[32m  Конфигурация успешно скопирована в /etc/rancher/rke2/rke2.yaml\033[0m"

# Устанавливаем необходимые RBAC настройки
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации rbac.yaml\033[0m"; exit 1;
}

# Устанавливаем kube-vip Cloud Controller
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации kube-vip-cloud-controller.yaml\033[0m"; exit 1;
}

# Проверяем статус установки
kubectl rollout status deployment/kube-vip-cloud-provider -n kube-system || {
  echo -e "\033[31m  Ошибка установки kube-vip Cloud Provider\033[0m"; exit 1;
}
echo -e "\033[32m  kube-vip Cloud Provider успешно установлен\033[0m"
echo -e "\033[32m--------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mЭтап 4: Подключаем остальные серверы и агенты в кластер RKE2\033[0m"
####################################################################################################################
# Извлекаем токен
token=$(<token)
for newnode in "${allserversnorke2s1[@]}"; do
  ssh -q -t -i "$HOME/.ssh/$certName" "$user@$newnode" sudo su <<EOF
    # Синхронизация времени
    echo -e "\033[32m  Синхронизация времени на сервере $newnode\033[0m"
    timedatectl set-ntp off || {
      echo -e "\033[31m    Ошибка при отключении NTP, установка прервана\033[0m"; exit 1;
    }
    timedatectl set-ntp on || {
      echo -e "\033[31m    Ошибка при включении NTP, установка прервана\033[0m"; exit 1;
    }
    echo -e "\033[32m  Синхронизация времени выполнена\033[0m"

    # Создаем директории и файл конфигурации
    mkdir -p /etc/rancher/rke2
    touch /etc/rancher/rke2/config.yaml
    
    # Записываем токен и адрес сервера в конфигурацию
    echo "token: $token" >> /etc/rancher/rke2/config.yaml
    echo "server: https://$rke2s1:9345" >> /etc/rancher/rke2/config.yaml
    echo "tls-san:" >> /etc/rancher/rke2/config.yaml
    echo "  - $vip" >> /etc/rancher/rke2/config.yaml
    echo "  - $rke2s1" >> /etc/rancher/rke2/config.yaml
    echo "  - $rke2s2" >> /etc/rancher/rke2/config.yaml
    echo "  - $rke2s3" >> /etc/rancher/rke2/config.yaml
    
    # Устанавливаем RKE2
    curl -sfL https://get.rke2.io | sh - && echo -e "\033[32m  RKE2 успешно установлен\033[0m" || {
      echo -e "\033[31m  Ошибка при установке RKE2\033[0m"; exit 1;
    }

    # Включаем и запускаем службы RKE2
    systemctl enable rke2-server.service
    systemctl start rke2-server.service

    exit
EOF
  echo -e "\033[32;5m  Сервер $newnode успешно присоединился\033[0m"
  echo -e "\033[32m--------------------------------\033[0m"
done

for newnode in "${allagents[@]}"; do
  ssh -q -t -i "$HOME/.ssh/$certName" "$user@$newnode" sudo su <<EOF
    # Синхронизация времени
    echo -e "\033[32m  Синхронизация времени на агенте $newnode\033[0m"
    timedatectl set-ntp off || {
      echo -e "\033[31m    Ошибка при отключении NTP, установка прервана\033[0m"; exit 1;
    }
    timedatectl set-ntp on || {
      echo -e "\033[31m    Ошибка при включении NTP, установка прервана\033[0m"; exit 1;
    }
    echo -e "\033[32m  Синхронизация времени выполнена\033[0m"

    # Создаем директории и файл конфигурации
    mkdir -p /etc/rancher/rke2
    touch /etc/rancher/rke2/config.yaml

    # Записываем токен и адрес сервера в конфигурацию
    echo "token: $token" >> /etc/rancher/rke2/config.yaml
    echo "server: https://$vip:9345" >> /etc/rancher/rke2/config.yaml
    echo "node-label:" >> /etc/rancher/rke2/config.yaml
    echo "  - worker=true" >> /etc/rancher/rke2/config.yaml
    echo "  - longhorn=true" >> /etc/rancher/rke2/config.yaml

    # Устанавливаем RKE2
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - && echo -e "\033[32m  RKE2 успешно установлен\033[0m" || {
      echo -e "\033[31m  Ошибка при установке RKE2\033[0m"; exit 1;
    }

    # Включаем и запускаем службы RKE2
    systemctl enable rke2-agent.service
    systemctl start rke2-agent.service

    exit
EOF
  echo -e "\033[32;5m  Агент $newnode успешно присоединился\033[0m"
  echo -e "\033[32m--------------------------------\033[0m"
done


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mЭтап 5: Развертываем Metallb\033[0m"
####################################################################################################################
# Создаем пространство имен
echo -e "\033[32;5m  Создаем пространство имен\033[0m"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации namespace.yaml\033[0m"; exit 1;
}

# Устанавливаем Metallb
echo -e "\033[32;5m  Применяем metallb-native.yaml\033[0m"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации metallb-native.yaml\033[0m"; exit 1;
}

# Проверка lbrange
[ -z "$lbrange" ] && {
  echo -e "\033[31m  Ошибка, переменная lbrange не задана\033[0m"; exit 1;
}

# Создаем файл ipAddressPool.yaml с содержимым
echo -e "\033[32m  Создаем файл $HOME/ipAddressPool.yaml\033[0m"
cat <<EOF | sudo tee "$HOME/ipAddressPool.yaml" > /dev/null
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - $lbrange
EOF

# Применяем конфигурацию IPAddressPool
echo -e "\033[32;5m  Применяем конфигурацию ipAddressPool.yaml\033[0m"
kubectl apply -f $HOME/ipAddressPool.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации ipAddressPool.yaml\033[0m"; exit 1;
}

# Развертываем пула IP адресов и l2Advertisement
echo -e "\033[32;5m  Добавляем пула IP адресов, ждем доступности Metallb\033[0m"
kubectl wait --namespace metallb-system \
             --for=condition=ready pod \
             --selector=component=controller \
             --timeout=900s

echo -e "\033[32m  Создаем файл $HOME/l2Advertisement.yaml\033[0m"
cat <<EOF | sudo tee "$HOME/l2Advertisement.yaml" > /dev/null
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF

# Применяем конфигурацию l2Advertisement
echo -e "\033[32;5m  Применяем конфигурацию l2Advertisement.yaml\033[0m"
kubectl apply -f $HOME/l2Advertisement.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации l2Advertisement.yaml\033[0m"; exit 1;
}

# Проверяем состояние узлов
echo -e "\033[32m  Состояние узлов:\033[0m"
kubectl get nodes
echo -e "\033[32m--------------------------------\033[0m"
echo -e "\033[32mКластер RKE2 создан и готов к работе!\033[0m"
echo -e "\033[32m--------------------------------\033[0m"