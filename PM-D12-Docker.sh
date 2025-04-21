#!/bin/bash

set -e
set -o pipefail

# Цвета для вывода (NC устанавливать после выводимого текста)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Проверка прав root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Скрипт должен быть запущен от имени пользователя root${NC}" >&2; exit 1
fi

# Конфигурация
VMID=9001
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
IMAGE="debian-12-generic-amd64+docker.qcow2"

# Определение типа хранилища
if pvesm status | grep -q "local-zfs"; then
    STORAGE="local-zfs"
elif pvesm status | grep -q "local-lvm"; then
    STORAGE="local-lvm"
else
    STORAGE="local"
fi

echo -e "${GREEN}Использование хранилища: $STORAGE${NC}"

REAL_USER=$(who am i | awk '{print $1}')
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    read -p "Введите имя пользователя для шаблона: " REAL_USER
    if [ -z "$REAL_USER" ]; then
        echo -e "${RED}Имя пользователя не указано, установка прервана${NC}"; exit 1
    fi
fi

SSH_KEY_PATH=""
if [ -f "/home/$REAL_USER/.ssh/authorized_keys" ]; then
    SSH_KEY_PATH="/home/$REAL_USER/.ssh/authorized_keys"
elif [ -f "/root/.ssh/authorized_keys" ]; then
    SSH_KEY_PATH="/root/.ssh/authorized_keys"
fi

echo -e "${GREEN}Создание шаблона виртуальной машины для пользователя: $REAL_USER${NC}"
echo -e "${GREEN}Путь к ключу SSH: $SSH_KEY_PATH${NC}"

if [ ! -f "$IMAGE" ]; then
    echo -e "${YELLOW}Загрузка и подготовка образа...${NC}"
    wget -q "$IMAGE_URL" -O "$IMAGE"
fi

qemu-img resize "$IMAGE" 10G
qm destroy "$VMID" &>/dev/null || true

echo -e "${GREEN}Создание структуры виртуальной машины...${NC}"
qm create "$VMID" --name "Debian-12-Docker" --ostype l26 \
    --memory 2048 --balloon 0 \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 "$STORAGE:0,pre-enrolled-keys=0" \
    --cpu host --cores 1 --numa 1 \
    --vga serial0 --serial0 socket \
    --net0 virtio,bridge=vmbr0,mtu=1

qm importdisk "$VMID" "$IMAGE" "$STORAGE"
qm set "$VMID" --scsihw virtio-scsi-pci --virtio0 "$STORAGE:vm-$VMID-disk-1,discard=on"
qm set "$VMID" --boot order=virtio0
qm set "$VMID" --scsi1 "$STORAGE:cloudinit"

echo -e "${YELLOW}Настройка Cloud-Init...${NC}"
mkdir -p /var/lib/vz/snippets
cat << 'EOF' > /var/lib/vz/snippets/debian-docker.yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - vim
  - htop
  - iotop
  - tmux

runcmd:
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  - echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update
  - apt-get install -y sudo docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - usermod -aG sudo ${user}
  - timedatectl set-timezone Europe/Minsk
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - reboot
EOF

qm set "$VMID" --cicustom "vendor=local:snippets/debian-docker.yaml"
qm set "$VMID" --tags template
qm set "$VMID" --ciuser "$REAL_USER"
if [ -n "$SSH_KEY_PATH" ]; then
    qm set "$VMID" --sshkeys "$SSH_KEY_PATH"
else
    echo -e "${YELLOW}Внимание: SSH не найден, нужно настроить SSH-доступ вручную${NC}"
fi
qm set "$VMID" --ipconfig0 ip=dhcp
qm template "$VMID"

rm -f "$IMAGE"
echo -e "${GREEN}Шаблон успешно создан, ID: $VMID${NC}"
