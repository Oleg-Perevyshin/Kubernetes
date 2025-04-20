#!/bin/bash

set -e

# Check root privileges
if [ "$(id -u)" != "0" ]; then
   echo "Скрипт должен быть запущен от имени пользователя root" >&2
   exit 1
fi

# Configuration
VMID=9001
RAM=2048
CORES=1
DISK=5G
CPU=host
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
IMAGE="debian-12-generic-amd64+docker.qcow2"

detect_storage() {
    if pvesm status | grep -q "local-zfs"; then
        echo "local-zfs"
    elif pvesm status | grep -q "local-lvm"; then
        echo "local-lvm"
    else
        echo "local"
    fi
}

STORAGE=$(detect_storage)
echo "Использование хранилища: $STORAGE"

if [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER=$(who am i | awk '{print $1}')
    if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
        REAL_USER=$(logname 2>/dev/null || echo "")
    fi
fi

if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    read -p "Введите имя пользователя для шаблона: " REAL_USER
    if [ -z "$REAL_USER" ]; then
        echo "Имя пользователя не указано, установка прервана"
        exit 1
    fi
fi

SSH_KEY_PATH=""
if [ -f "/home/$REAL_USER/.ssh/authorized_keys" ]; then
    SSH_KEY_PATH="/home/$REAL_USER/.ssh/authorized_keys"
elif [ -f "/root/.ssh/authorized_keys" ]; then
    SSH_KEY_PATH="/root/.ssh/authorized_keys"
fi

echo "Создание шаблона виртуальной машины для пользователя: $REAL_USER"
echo "Путь к ключу SSH: $SSH_KEY_PATH"

prepare_image() {
    echo "Загрузка и подготовка образа"
    wget -q "$IMAGE_URL" -O "$IMAGE"
    qemu-img resize "$IMAGE" "$DISK"
    qm destroy "$VMID" &>/dev/null || true
}

create_vm() {
    echo "Создание структуры виртуальной машины"
    qm create "$VMID" --name "Debian-12 (Docker)" --ostype l26 \
        --memory "$RAM" --balloon 0 \
        --agent 1 \
        --bios ovmf --machine q35 --efidisk0 "$STORAGE:0,pre-enrolled-keys=0" \
        --cpu "$CPU" --cores "$CORES" --numa 1 \
        --vga serial0 --serial0 socket \
        --net0 virtio,bridge=vmbr0,mtu=1

    qm importdisk "$VMID" "$IMAGE" "$STORAGE"
    
    if [[ "$STORAGE" == "local-zfs" ]]; then
        qm set "$VMID" --scsihw virtio-scsi-pci --virtio0 "$STORAGE:vm-$VMID-disk-1,discard=on"
    else
        qm set "$VMID" --scsihw virtio-scsi-pci --virtio0 "$STORAGE:vm-$VMID-disk-1,discard=on"
    fi
    
    qm set "$VMID" --boot order=virtio0
    qm set "$VMID" --scsi1 "$STORAGE:cloudinit"
}

setup_cloud_init() {
    echo "Настройка Cloud-Init..."
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
        echo "Внимание: SSH не найден, нужно настроить SSH-доступ вручную"
    fi
    
    qm set "$VMID" --ipconfig0 ip=dhcp
    qm template "$VMID"
}

# Main execution
echo "Создание шаблона запущено..."
prepare_image
create_vm
setup_cloud_init
rm -f "$IMAGE"
echo "Шаблон успешно создан, ID: $VMID"
