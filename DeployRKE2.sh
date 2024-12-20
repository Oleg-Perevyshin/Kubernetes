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
rke2a3=192.168.5.16
rke2a1s=192.168.5.17
rke2a2s=192.168.5.18
rke2a3s=192.168.5.19

# Диапазон адресов балансировщика нагрузки
lbrange="192.168.5.21-192.168.5.39"

# Общий массив элементов кластера
allclasteritems=("$rke2s1" "$rke2s2" "$rke2s3" "$rke2a1" "$rke2a2" "$rke2a3" "$rke2a1s" "$rke2a2s" "$rke2a3s")

# Массив серверов
arrayservers=("$rke2s1" "$rke2s2" "$rke2s3")
arrayallserversnorke2s1=("$rke2s2" "$rke2s3")

# Массив агентов
arrayagents=("$rke2a1" "$rke2a2" "$rke2a3")

# Массив агентов хранилища
arraystorageagents=("$rke2a1s" "$rke2a2s" "$rke2a3s")

####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 1: Подготовка для установки кластера RKE2\033[0m"
####################################################################################################################
# Проверка доступности всех узлов
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32m  Проверка доступности узлов\033[0m"
for node in "${allclasteritems[@]}"; do
  ping -c 1 -W 1 "$node" > /dev/null || {
    echo -e "\033[31m    Узел $node недоступен, установка прервана\033[0m"; exit 1;
  }
done
echo -e "\033[32m  Все узлы кластера доступны\033[0m"
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32m  Синхронизация времени на управляющей машине\033[0m"
sudo timedatectl set-ntp off || {
  echo -e "\033[31m    Ошибка при отключении NTP, установка прервана\033[0m"; exit 1;
}
sudo timedatectl set-ntp on || {
  echo -e "\033[31m    Ошибка при включении NTP, установка прервана\033[0m"; exit 1;
}
echo -e "\033[32m  Синхронизация времени выполнена\033[0m"
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
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
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
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
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
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
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
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
sed 's/$interface/'"$interface"'/g; s/$vip/'"$vip"'/g; s/\$KVVERSION/'"$KVVERSION"'/g' | \
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
for newnode in "${arrayservers[@]}"; do
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
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
# Подключаемся к rke2s1, устанавливаем RKE2, копируем токен обратно на машину администратора
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
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

  # Перемещение файлов
  mv "/home/$user/kube-vip.yaml" "/var/lib/rancher/rke2/server/manifests/kube-vip.yaml" && {
    echo -e "\033[32m  Файл /home/$user/kube-vip.yaml перемещен\033[0m"
  } || {
    echo -e "\033[31m  Ошибка перемещения /home/$user/kube-vip.yaml\033[0m"; exit 1;
  }
  mv "/home/$user/config.yaml" "/etc/rancher/rke2/config.yaml" && {
    echo -e "\033[32m  Файл /home/$user/config.yaml перемещен\033[0m"
  } || {
    echo -e "\033[31m  Ошибка перемещения /home/$user/config.yaml\033[0m"; exit 1;
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

# Копируем токен и конфигурацию
echo -e "\033[32m  Копируем токен и конфигурацию с $rke2s1 на $rke2m...\033[0m"
if ssh -i "$HOME/.ssh/$certName" "$user@$rke2s1" "sudo cat /var/lib/rancher/rke2/server/token" > "$HOME/token"; then
  echo -e "\033[32m  Токен успешно скопирован с $rke2s1\033[0m"
else
  echo -e "\033[31m  Ошибка при копировании токена с $rke2s1\033[0m"
  exit 1
fi

if ssh -i "$HOME/.ssh/$certName" "$user@$rke2s1" "sudo cat /etc/rancher/rke2/rke2.yaml" > "$HOME/.kube/rke2.yaml"; then
  echo -e "\033[32m  Конфигурация успешно скопирована с $rke2s1\033[0m"
else
  echo -e "\033[31m  Ошибка при копировании конфигурации с $rke2s1\033[0m"
  exit 1
fi

# Задаем файл конфигурации для kubectl
config_file="$HOME/.kube/config"

# Обновляем конфигурацию и заменяем IP-адрес
sudo sed "s/127.0.0.1/$rke2s1/g" "$HOME/.kube/rke2.yaml" > "$config_file"

# Устанавливаем владельца файла конфигурации
sudo chown "$(id -u):$(id -g)" "$config_file"

# Устанавливаем переменную окружения KUBECONFIG
export KUBECONFIG="$config_file"

# Копируем конфигурацию в RKE2
sudo cp "$config_file" /etc/rancher/rke2/rke2.yaml || {
  echo -e "\033[31m  Ошибка при копировании конфигурации\033[0m"; exit 1;
}
chmod 600 "$config_file"

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
echo -e "\033[32m  kube-vip-cloud-provider успешно установлен\033[0m"
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 4: Подключаем остальные серверы и агенты в кластер RKE2\033[0m"
####################################################################################################################
# Извлекаем токен
echo -e "\033[32m  Подключаем серверы в кластер RKE2\033[0m"
token=$(<token)
for newnode in "${arrayallserversnorke2s1[@]}"; do
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

    # Удаляем файл, если он существует
    rm -f /etc/rancher/rke2/config.yaml
    
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
  echo -e "\033[32m  Сервер $newnode успешно присоединился\033[0m"
  echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
done

echo -e "\033[32m  Подключаем агенты в кластер RKE2\033[0m"
for newnode in "${arrayagents[@]}"; do
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

    # Удаляем файл, если он существует
    rm -f /etc/rancher/rke2/config.yaml

    # Записываем токен и адрес сервера в конфигурацию
    echo "token: $token" >> /etc/rancher/rke2/config.yaml
    echo "server: https://$vip:9345" >> /etc/rancher/rke2/config.yaml
    echo "node-label:" >> /etc/rancher/rke2/config.yaml
    echo "  - worker=true" >> /etc/rancher/rke2/config.yaml

    # Устанавливаем RKE2
    curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh - && echo -e "\033[32m  RKE2 успешно установлен\033[0m" || {
      echo -e "\033[31m  Ошибка при установке RKE2\033[0m"; exit 1;
    }

    # Включаем и запускаем службы RKE2
    systemctl enable rke2-agent.service
    systemctl start rke2-agent.service

    exit
EOF
  echo -e "\033[32m  Агент $newnode успешно присоединился\033[0m"
  echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
done


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 5: Развертываем Metallb\033[0m"
####################################################################################################################
# Создаем пространство имен
echo -e "\033[32m  Создаем пространство имен\033[0m"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации namespace.yaml\033[0m"; exit 1;
}

# Устанавливаем Metallb
echo -e "\033[32m  Применяем metallb-native.yaml\033[0m"
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации metallb-native.yaml\033[0m"; exit 1;
}

# Ожидаем, пока все компоненты MetalLB будут готовы
echo -e "\033[32m  Ожидаем готовности компонентов MetalLB...\033[0m"
kubectl wait --namespace metallb-system --for=condition=available deployment/controller --timeout=900s || {
  echo -e "\033[31m  Время ожидания истекло, контроллер MetalLB не готов\033[0m"; exit 1;
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
echo -e "\033[32m  Применяем конфигурацию ipAddressPool.yaml\033[0m"
kubectl apply -f $HOME/ipAddressPool.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации ipAddressPool.yaml\033[0m"; exit 1;
}

# Развертываем пула IP адресов и l2Advertisement
echo -e "\033[32m  Добавляем пула IP адресов, ждем доступности Metallb\033[0m"
kubectl wait --namespace metallb-system \
             --for=condition=ready pod \
             --selector=component=controller \
             --timeout=900s || {
  echo -e "\033[31m  Время ожидания истекло, Metallb не готов\033[0m"; exit 1;
}

# Ожидаем, пока все поды в пространстве имен metallb-system будут готовы
echo -e "\033[32m  Ожидаем запуска все подов Metallb...\033[0m"
kubectl wait --namespace metallb-system \
             --for=condition=ready pod \
             --selector=app=metallb \
             --timeout=900s || {
  echo -e "\033[31m  Время ожидания истекло, не все поды Metallb готовы\033[0m"; exit 1;
}

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
echo -e "\033[32m  Применяем конфигурацию l2Advertisement.yaml\033[0m"
kubectl apply -f $HOME/l2Advertisement.yaml || {
  echo -e "\033[31m  Ошибка применения конфигурации l2Advertisement.yaml\033[0m"; exit 1;
}

# Ожидаем, пока все узлы станут Ready
echo -e "\033[32m  Ожидаем запуска всех узлов...\033[0m"
for node in $(kubectl get nodes -o name); do
  kubectl wait --for=condition=Ready "$node" --timeout=900s || {
    echo -e "\033[31m  Время ожидания истекло, узел $node не готов\033[0m"; exit 1;
  }
done

# Проверяем состояние узлов
echo -e "\033[32m  Состояние узлов:\033[0m"
kubectl get nodes
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mКластер RKE2 создан и готов к работе!\033[0m"
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 6: Установка Rancher\033[0m"
####################################################################################################################
# Устанавливаем Helm
echo -e "\033[32m  Устанавливаем Helm\033[0m"
if ! command -v helm &> /dev/null; then
  curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 || {
    echo -e "\033[31m  Ошибка при загрузке скрипта установки Helm\033[0m"; exit 1;
  }
  chmod 700 get_helm.sh
  ./get_helm.sh || {
    echo -e "\033[31m  Ошибка при установке Helm\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  Helm уже установлен, проверка версии...\033[0m"
  helm version || {
    echo -e "\033[31m  Ошибка при проверке версии Helm\033[0m"; exit 1;
  }
fi

# Добавляем репозиторий Rancher
echo -e "\033[32m  Добавляем репозиторий Rancher\033[0m"
if ! helm repo list | grep -q "rancher-latest"; then
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest || {
    echo -e "\033[31m  Ошибка при добавлении репозитория Rancher\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  Репозиторий Rancher уже добавлен\033[0m"
fi

# Создаем пространство имен для Rancher
echo -e "\033[32m  Создаем пространство имен cattle-system\033[0m"
if ! kubectl get namespace cattle-system &> /dev/null; then
  kubectl create namespace cattle-system || {
    echo -e "\033[31m  Ошибка при создании пространства имен cattle-system\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  Пространство имен cattle-system уже существует\033[0m"
fi

# Создаем пространство имен для Cert-Manager
echo -e "\033[32m  Создаем пространство имен cert-manager\033[0m"
if ! kubectl get namespace cert-manager &> /dev/null; then
  kubectl create namespace cert-manager || {
    echo -e "\033[31m  Ошибка при создании пространства имен cert-manager\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  Пространство имен cert-manager уже существует\033[0m"
fi

# Развертываем Cert-Manager
echo -e "\033[32m  Развертываем Cert-Manager\033[0m"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.crds.yaml || {
  echo -e "\033[31m  Ошибка при применении CRDs Cert-Manager\033[0m"; exit 1;
}

helm repo add jetstack https://charts.jetstack.io || {
  echo -e "\033[31m  Ошибка при добавлении репозитория Jetstack\033[0m"; exit 1;
}

helm repo update || {
  echo -e "\033[31m  Ошибка при обновлении репозиториев Helm\033[0m"; exit 1;
}

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.2 || {
    echo -e "\033[31m  Ошибка при установке Cert-Manager\033[0m"; exit 1;
}

# Ожидаем готовности Cert-Manager
echo -e "\033[32m  Ожидаем готовности Cert-Manager...\033[0m"
kubectl wait --namespace cert-manager --for=condition=available deployment/cert-manager --timeout=60s || {
  echo -e "\033[31m  Cert-Manager не готов\033[0m"; exit 1;
}

# Устанавливаем Rancher
echo -e "\033[32m  Развертываем Rancher\033[0m"
if ! kubectl -n cattle-system get deploy rancher &> /dev/null; then
  helm install rancher rancher-latest/rancher \
    --namespace cattle-system \
    --set hostname=rancher.poe-gw.keenetic.pro \
    --set bootstrapPassword=MCMega20051983! || {
      echo -e "\033[31m  Ошибка при развертывании Rancher\033[0m"; exit 1;
    }
  kubectl -n cattle-system rollout status deploy/rancher || {
    echo -e "\033[31m  Ошибка при проверке статуса развертывания Rancher\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  Rancher уже развернут\033[0m"
fi

# Добавляем LoadBalancer для Rancher
echo -e "\033[32m  Добавляем LoadBalancer для Rancher\033[0m"
if ! kubectl get svc -n cattle-system | grep -q "rancher-lb"; then
  kubectl expose deployment rancher --name=rancher-lb --port=443 --type=LoadBalancer -n cattle-system || {
    echo -e "\033[31m  Ошибка при создании LoadBalancer для Rancher\033[0m"; exit 1;
  }
else
  echo -e "\033[32m  LoadBalancer для Rancher уже создан\033[0m"
fi

# Ожидаем готовности LoadBalancer
echo -e "\033[32m  Ожидаем готовности LoadBalancer...\033[0m"
while [[ $(kubectl get svc -n cattle-system -o jsonpath='{..status.conditions[?(@.type=="Pending")].status}') = "True" ]]; do
  sleep 10
done

kubectl get svc -n cattle-system || {
  echo -e "\033[31m  Ошибка при получении информации о сервисах после ожидания\033[0m"; exit 1;
}

# Проверяем состояние узлов
echo -e "\033[32m  Состояние узлов:\033[0m"
kubectl get nodes
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mДоступ к Rancher по указанному IP (пароль: MCMega20051983!)\033[0m"
echo -e "\033[32mRancher установлен и готов к работе!\033[0m"
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"


####################################################################################################################
####################################################################################################################
####################################################################################################################
####################################################################################################################
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mЭтап 7: Установка Longhorn\033[0m"
####################################################################################################################
# Устанавливаем Open-ISCSI (необходимо для Debian и не облачного Ubuntu)
command -v sudo service open-iscsi status &> /dev/null || {
  echo -e " \033[31m  Open-ISCSI не найден, установливаем...\033[0m"
  sudo apt install open-iscsi || {
    echo -e " \033[31m  Ошибка при установке Open-ISCSI\033[0m"; exit 1;
  }
}

echo -e "\033[32m  Подключаем агенты хранилищ Longhorn в кластер RKE2\033[0m"
token=$(<token)
for newnode in "${arraystorageagents[@]}"; do
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

    # Удаляем файл, если он существует
    rm -f /etc/rancher/rke2/config.yaml

    # Записываем токен и адрес сервера в конфигурацию
    echo "token: $token" >> /etc/rancher/rke2/config.yaml
    echo "server: https://$vip:9345" >> /etc/rancher/rke2/config.yaml
    echo "node-label:" >> /etc/rancher/rke2/config.yaml
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
  echo -e "\033[32m  Агент $newnode успешно присоединился\033[0m"
  echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
done

# Установливаем Longhorn (используя измененный официальный файл для привязки к узлам Longhorn)
kubectl apply -f https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/Longhorn/longhorn.yaml

# Следим за состоянием подов в пространстве имен longhorn-system
kubectl get pods --namespace longhorn-system --watch

# Проверяем состояние узлов
echo -e "\033[32m  Состояние узлов:\033[0m"
kubectl get nodes
echo -e "\033[32m  Службы Longhorn в пространстве имен longhorn-system:\033[0m"
kubectl get svc -n longhorn-system
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"
echo -e "\033[32mLonghorn установлен и готов к работе!\033[0m"
echo -e "\033[32m------------------------------------------------------------------------------------------\033[0m"