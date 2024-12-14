#############################
# РАЗДЕЛ ДЛЯ РЕДАКТИРОВАНИЯ #
#############################

# Версия Kube-VIP
KVVERSION="v0.8.7"

# Версия K3S
k3sVersion="v1.31.3+k3s1"

# Установка IP адресов серверов и агентов
k3s-s1=192.168.5.21
k3s-s2=192.168.5.22
k3s-s3=192.168.5.23
k3s-a1=192.168.5.24
k3s-a2=192.168.5.25

# Имя пользователя на машинах
user=poe

# Серевой интерфейс на машинах
interface=net0

# Установка виртуального IP адреса (VIP)
vip=192.168.5.20

# Массив серверов
masters=($k3s-s2 $k3s-s3)

# Массив агентов
workers=($k3s-a1 $k3s-a2)

# Общий массив
all=($k3s-s1 $k3s-s2 $k3s-s3 $k3s-a1 $k3s-a2)

# Общий массив без первого сервера
allnomaster1=($k3s-s2 $k3s-s3 $k3s-a1 $k3s-a2)

# Диапазон адресов балансировщика нагрузки
lbrange=192.168.5.26-192.168.5.28

# Переменная для ssh сертификата
certName=id_rsa

# Файл настроек ssh
config_file=~/.ssh/config

#############################
# РАЗДЕЛ БЕЗ РЕДАКТИРОВАНИЯ #
#############################

# Запускаем автоматическую синхронизацию времени
sudo timedatectl set-ntp off
sudo timedatectl set-ntp on

# Перемещаем сертификаты SSH в ~/.ssh и изменяем разрешения
cp /home/$user/{$certName,$certName.pub} /home/$user/.ssh
chmod 600 /home/$user/.ssh/$certName 
chmod 644 /home/$user/.ssh/$certName.pub

# Устанавливаем k3sup на локальную машину
if ! command -v k3sup version &> /dev/null
then
    echo -e " \033[31;5mk3sup not found, installing\033[0m"
    curl -sLS https://get.k3sup.dev | sh
    sudo install k3sup /usr/local/bin/
else
    echo -e " \033[32;5mk3sup already installed\033[0m"
fi

# Устанавливаем Kubectl
if ! command -v kubectl version &> /dev/null
then
    echo -e " \033[31;5mKubectl not found, installing\033[0m"
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
else
    echo -e " \033[32;5mKubectl already installed\033[0m"
fi

# Проверьте наличие файла конфигурации SSH
# Создайте его при необходимости, добавьте/измените строгую проверку ключа хоста

if [ ! -f "$config_file" ]; then
  # Создаем файл и добавляем строку
  echo "StrictHostKeyChecking no" > "$config_file"
  # Устанавливаем разрешения на чтение и запись только для владельца
  chmod 600 "$config_file"
  echo "File created and line added."
else
  # Проверяем, существует ли строка
  if grep -q "^StrictHostKeyChecking" "$config_file"; then
    # Проверяем, не равно ли значение "no"
    if ! grep -q "^StrictHostKeyChecking no" "$config_file"; then
      # Заменяем существующую строку
      sed -i 's/^StrictHostKeyChecking.*/StrictHostKeyChecking no/' "$config_file"
      echo "Line updated."
    else
      echo "Line already set to 'no'."
    fi
  else
    # Добавляем строку в конце файла
    echo "StrictHostKeyChecking no" >> "$config_file"
    echo "Line added."
  fi
fi

# Добавляем ssh ключ ко всем нодам
for node in "${all[@]}"; do
  ssh-copy-id $user@$node
done

# Установливаем policycoreutils для каждого узла
for newnode in "${all[@]}"; do
  ssh $user@$newnode -i ~/.ssh/$certName sudo su <<EOF
  NEEDRESTART_MODE=a apt-get install policycoreutils -y
  exit
EOF
  echo -e " \033[32;5mPolicyCoreUtils installed!\033[0m"
done

# Шаг 1: Bootstrap Первый узел k3s
mkdir ~/.kube
k3sup install \
  --ip $k3s-s1 \
  --user $user \
  --tls-san $vip \
  --cluster \
  --k3s-version $k3sVersion \
  --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$k3s-s1 --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
  --merge \
  --sudo \
  --local-path $HOME/.kube/config \
  --ssh-key $HOME/.ssh/$certName \
  --context k3s-ha
echo -e " \033[32;5mFirst Node bootstrapped successfully!\033[0m"

# Шаг 2: Устанавливаем Kube-VIP для HA (высокой доступности)
kubectl apply -f https://kube-vip.io/manifests/rbac.yaml

# Шаг 3: Скачиваем kube-vip deploy/kube-vip
curl -sO https://raw.githubusercontent.com/Oleg-Perevyshin/k3s/refs/heads/main/deploy/kube-vip
cat kube-vip | sed 's/$interface/'$interface'/g; s/$vip/'$vip'/g' > $HOME/kube-vip.yaml

# Шаг 4: Копируем kube-vip.yaml на k3s-s1
scp -i ~/.ssh/$certName $HOME/kube-vip.yaml $user@$k3s-s1:~/kube-vip.yaml

# Шаг 5: Подключаемся к k3s-s1 и перемещаем kube-vip.yaml
ssh $user@$k3s-s1 -i ~/.ssh/$certName <<- EOF
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests
  sudo mv kube-vip.yaml /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
EOF

# Шаг 6: Добавляем серверы и агенты
for newnode in "${masters[@]}"; do
  k3sup join \
    --ip $newnode \
    --user $user \
    --sudo \
    --k3s-version $k3sVersion \
    --server \
    --server-ip $k3s-s1 \
    --ssh-key $HOME/.ssh/$certName \
    --k3s-extra-args "--disable traefik --disable servicelb --flannel-iface=$interface --node-ip=$newnode --node-taint node-role.kubernetes.io/master=true:NoSchedule" \
    --server-user $user
  echo -e " \033[32;5mMaster node joined successfully!\033[0m"
done

for newagent in "${workers[@]}"; do
  k3sup join \
    --ip $newagent \
    --user $user \
    --sudo \
    --k3s-version $k3sVersion \
    --server-ip $k3s-s1 \
    --ssh-key $HOME/.ssh/$certName \
    --k3s-extra-args "--node-label \"longhorn=true\" --node-label \"worker=true\""
  echo -e " \033[32;5mAgent node joined successfully!\033[0m"
done

# Шаг 7: Устанавливаем kube-vip в качестве сетевого балансировщика нагрузки
kubectl apply -f https://raw.githubusercontent.com/kube-vip/kube-vip-cloud-provider/main/manifest/kube-vip-cloud-controller.yaml

# Шаг 8: Устанавливаем Metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.12.1/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml
# Скачиваем ipAddressPool и настраиваем с помощью lbrange
curl -sO https://raw.githubusercontent.com/Oleg-Perevyshin/k3s/refs/heads/main/deploy/ipAddressPool
cat ipAddressPool | sed 's/$lbrange/'$lbrange'/g' > $HOME/ipAddressPool.yaml
kubectl apply -f $HOME/ipAddressPool.yaml

# Шаг 9: Тестируем с Nginx
kubectl apply -f https://raw.githubusercontent.com/inlets/inlets-operator/master/contrib/nginx-sample-deployment.yaml -n default
kubectl expose deployment nginx-1 --port=80 --type=LoadBalancer -n default

echo -e " \033[32;5mWaiting for K3S to sync and LoadBalancer to come online\033[0m"

while [[ $(kubectl get pods -l app=nginx -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
   sleep 1
done

# Шаг 10: Разворачиваем пулы IP и l2Advertisement
kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=component=controller \
                --timeout=120s
kubectl apply -f ipAddressPool.yaml
kubectl apply -f https://raw.githubusercontent.com/Oleg-Perevyshin/k3s/refs/heads/main/deploy/l2Advertisement.yaml

kubectl get nodes
kubectl get svc
kubectl get pods --all-namespaces -o wide

echo -e " \033[32;5mHappy Kubing! Access Nginx at EXTERNAL-IP above\033[0m"
