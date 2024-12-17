#!/bin/bash

# Редактируем значения переменных
# Версия K3S
k3sVersion="v1.31.3+k3s1"

# Установка IP адресов серверов и агентов
server01="192.168.5.11"
server02="192.168.5.12"
server03="192.168.5.13"
agent01="192.168.5.14"
agent02="192.168.5.15"

# Имя пользователя и пароль на удаленных машинах
user="poe"
password="MCMega2005!"

# Серевой интерфейс на машинах
interface="ens18"

# Установка виртуального IP адреса (VIP)
vip="192.168.5.20"

# Массив серверов
servers=("$server02" "$server03")

# Массив агентов
agents=("$agent01" "$agent02")

# Общий массив
all=("$server01" "$server02" "$server03" "$agent01" "$agent02")

# Диапазон адресов балансировщика нагрузки
lbrange="192.168.5.40-192.168.5.59"

# Переменная для ssh сертификата
certName="id_rsa"

# Файл настроек ssh
config_file="$HOME/.ssh/config"


#############################
# Проверка доступности всех узлов
echo -e "\033[32;5mПРОВЕРКА ДОСТУПНОСТИ УЗЛОВ\033[0m"
for node in "${all[@]}"; do
  if ! ping -c 1 -W 1 "$node" > /dev/null; then
    echo -e "\033[31;5mОшибка: Узел $node недоступен, установка прервана\033[0m"
    exit 1
  else
    echo -e "\033[32;5mУзел $node доступен\033[0m"
  fi
done

# Запускаем автоматическую синхронизацию времени
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# Изменяем разрешения для сертификата
chmod 600 "/home/$user/.ssh/$certName" 
chmod 644 "/home/$user/.ssh/$certName.pub"

# Устанавливаем K3sup на локальную машину
if ! command -v k3sup &> /dev/null; then
  echo -e " \033[31;5mK3sup не найден, выполняется установка...\033[0m"
  curl -sLS https://get.k3sup.dev | sh
  sudo install k3sup /usr/local/bin/
else
  echo -e " \033[32;5mK3sup уже установлен\033[0m"
fi

# Устанавливаем Kubectl
if ! command -v kubectl &> /dev/null; then
  echo -e " \033[31;5mKubectl не найден, выполняется установка...\033[0m"
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
  echo -e " \033[32;5mKubectl уже установлен\033[0m"
fi

# Проверка наличия файла конфигурации SSH
if [ ! -f "$config_file" ]; then
  # Создаем файл и добавляем строку
  echo "StrictHostKeyChecking no" > "$config_file"
  chmod 600 "$config_file"
  echo "Файл создан, значение StrictHostKeyChecking установлено на 'no'"
else
  # Проверяем, существует ли строка
  if grep -q "^StrictHostKeyChecking" "$config_file"; then
    # Проверяем, не равно ли значение "no"
    if ! grep -q "^StrictHostKeyChecking no" "$config_file"; then
      sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$config_file"
      echo "Значение StrictHostKeyChecking обновлено на 'no'"
    else
      echo "Значение StrictHostKeyChecking уже установлено на 'no'"
    fi
  else
    # Добавляем строку в конце файла
    echo "Добавлена строка StrictHostKeyChecking no" >> "$config_file"
  fi
fi

# Добавляем ssh ключ ко всем нодам
for node in "${all[@]}"; do
  ssh-copy-id "$user@$node"
done

# Устанавливаем policycoreutils для каждого узла
for newnode in "${all[@]}"; do
  sshpass -p "$password" ssh "$user@$newnode" -i "~/.ssh/$certName" "echo \"$password\" | sudo -S apt-get install policycoreutils -y"
  if [ $? -eq 0 ]; then
    echo -e " \033[32;5mPolicyCoreUtils успешно установлен на узле $newnode\033[0m"
  else
    echo -e " \033[31;5mНе удалось установить PolicyCoreUtils на узле $newnode, установка прервана\033[0m"
    exit 1
  fi
done

# Шаг 1: Bootstrap Первый узел k3s
setup_ntp() {
  local node=$1
  echo -e " \033[32;5mНастройка NTP на: $node\033[0m"
  ssh "$user@$node" << 'EOF'
    sudo timedatectl set-ntp off
    sudo timedatectl set-ntp on
    echo -e " \033[32;5mNTP настроен\033[0m"
EOF
}
setup_ntp "$server01"
mkdir -p ~/.kube
k3sup install \
  --ip $server01 \
  --user $user \
  --tls-san $vip \
  --cluster \
  --k3s-version $k3sVersion \
  --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$server01 --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
  --merge \
  --sudo \
  --local-path $HOME/.kube/config \
  --ssh-key $HOME/.ssh/$certName \
  --context k3s-ha
# Проверяем код возврата
if [ $? -eq 0 ]; then
  echo -e " \033[32;5mПервый сервер-узел успешно установлен!\033[0m"
else
  echo -e " \033[31;5mОшибка установки первого сервер-узла, установка прервана\033[0m"
  exit 1
fi

# Шаг 2: Устанавливаем Kube-VIP для HA (высокой доступности)
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml

# Шаг 3: Скачиваем kube-vip
curl -sO https://raw.githubusercontent.com/Oleg-Perevyshin/k3s/refs/heads/main/deploy/kube-vip
sed "s/\$interface/${interface}/g; s/\$vip/${vip}/g" kube-vip > "$HOME/kube-vip.yaml"

# Шаг 4: Копируем kube-vip.yaml на server01
scp -i "$HOME/.ssh/$certName" "$HOME/kube-vip.yaml" "$user@$server01:~/kube-vip.yaml"

# Шаг 5: Подключаемся к server01 и перемещаем kube-vip.yaml
ssh "$user@$server01" -i "$HOME/.ssh/$certName" <<- EOF
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests
  sudo mv ~/kube-vip.yaml /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
EOF

# Шаг 6: Добавляем серверы и агенты
for newnode in "${servers[@]}"; do
  setup_ntp "$newnode"
  k3sup join \
    --ip $newnode \
    --user $user \
    --sudo \
    --k3s-version $k3sVersion \
    --server \
    --server-ip $server01 \
    --ssh-key $HOME/.ssh/$certName \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$newnode --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --server-user $user
  
  if [ $? -eq 0 ]; then
    echo -e " \033[32;5mСервер $newnode успешно присоединился\033[0m"
  else
    echo -e " \033[31;5mСервер $newnode не присоединился, установка прервана\033[0m"
    exit 1
  fi
done

for newagent in "${agents[@]}"; do
  setup_ntp "$newagent"
  k3sup join \
    --ip "$newagent" \
    --user "$user" \
    --sudo \
    --k3s-version "$k3sVersion" \
    --server-ip "$server01" \
    --ssh-key "$HOME/.ssh/$certName" \
    --k3s-extra-args "--node-label longhorn=true --node-label worker=true"

  if [ $? -eq 0 ]; then
    echo -e " \033[32;5mАгент $newagent успешно присоединился\033[0m"
  else
    echo -e " \033[31;5mАгент $newagent не присоединился, установка прервана\033[0m"
    exit 1
  fi
done

# Шаг 7: Устанавливаем kube-vip в качестве сетевого балансировщика нагрузки
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml

# Шаг 8: Устанавливаем Metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# Создаем файл ipAddressPool.yaml и применяем (диапазон IP адресов для балансировщика нагрузки)
cat <<EOF > $HOME/ipAddressPool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: first-pool
  namespace: metallb-system
spec:
  addresses:
  - ${lbrange}
EOF
kubectl apply -f $HOME/ipAddressPool.yaml

# Шаг 9: Тестируем с Nginx
kubectl apply -f https://raw.githubusercontent.com/inlets/inlets-operator/master/contrib/nginx-sample-deployment.yaml -n default
kubectl expose deployment nginx-1 --port=80 --type=LoadBalancer -n default

echo -e " \033[32;5mОжидание синхронизации K3S и выхода LoadBalancer в онлайн\033[0m"

while [[ $(kubectl get pods -l app=nginx -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
   echo "Ожидание готовности подов Nginx..."
   sleep 10
done

# Шаг 10: Ожидаем готовности контроллера MetalLB
kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=component=controller \
                --timeout=120s

kubectl apply -f $HOME/ipAddressPool.yaml

# Создаем файл для L2Advertisement и применяем
cat <<EOF > $HOME/l2Advertisement.yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: example
  namespace: metallb-system
spec:
  ipAddressPools:
  - first-pool
EOF
kubectl apply -f $HOME/l2Advertisement.yaml

# Шаг 11: Вывод проверочной информации
kubectl get nodes
kubectl get svc
kubectl get pods --all-namespaces -o wide

echo -e " \033[32;5mУСТАНОВКА ЗАВЕРШЕНА\033[0m"
