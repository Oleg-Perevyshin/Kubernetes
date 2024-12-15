# Установка IP адреса главного сервера
server01="192.168.5.21"

# Установка IP адресов агентов
agent03="192.168.5.26"
agent04="192.168.5.27"
agent05="192.168.5.28"

# Имя пользователя и пароль на удаленных машинах
user="poe"
password="MCMega2005!"

# Серевой интерфейс на машинах
interface="ens18"

# Установка виртуального IP адреса (VIP)
vip="192.168.5.20"

# Массив агентов
storages=("$agent03" "$agent04" "$agent05")

# Переменная для ssh сертификата
certName="id_rsa"


#############################################
# Проверка доступности всех узлов
echo -e "\033[32;5mПРОВЕРКА ДОСТУПНОСТИ УЗЛОВ\033[0m"
for node in "${storages[@]}"; do
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

# Добавляем ssh ключ ко всем нодам
for node in "${storages[@]}"; do
  ssh-copy-id $user@$node
done

# Устанавливаем Open-ISCSI, если не установлено
if ! dpkg -l | grep -q open-iscsi; then
  echo -e " \033[31;5mOpen-ISCSI не найден, выполняется установка...\033[0m"
  sudo apt install -y open-iscsi
else
  echo -e " \033[32;5mOpen-ISCSI уже установлен\033[0m"
fi

# Шаг 1: Добавляем агенты (с лейблом longhorn=true)
setup_ntp() {
  local node=$1
  ssh "$user@$node" << 'EOF'
    sudo timedatectl set-ntp off
    sudo timedatectl set-ntp on
    echo -e " \033[32;5mNTP настроен\033[0m"
EOF
}
for newagent in "${storages[@]}"; do
  setup_ntp "$newagent"
  k3sup join \
    --ip $newagent \
    --user $user \
    --sudo \
    --k3s-channel stable \
    --server-ip $server01 \
    --k3s-extra-args "--node-label \"longhorn=true\"" \
    --ssh-key $HOME/.ssh/$certName
  
  if [ $? -eq 0 ]; then
    echo -e " \033[32;5mАгент $newagent успешно присоединился\033[0m"
  else
    echo -e " \033[31;5mАгент $newagent не присоединился, установка прервана\033[0m"
    exit 1
  fi
done

# Step 2: Install Longhorn (using modified Official to pin to Longhorn Nodes)
# kubectl apply -f https://raw.githubusercontent.com/JamesTurland/JimsGarage/main/Kubernetes/Longhorn/longhorn.yaml
# kubectl get pods \
# --namespace longhorn-system \
# --watch

# # Step 3: Print out confirmation
# kubectl get nodes
# kubectl get svc -n longhorn-system

echo -e " \033[32;5mУСТАНОВКА ЗАВЕРШЕНА\033[0m"
