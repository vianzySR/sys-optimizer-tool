#!/bin/bash
set -euo pipefail

SVC_NAME="svc-0"
SVC_RAM_MB=8192
SVC_VCPU=2
SVC_DISK=64
SSH_PORT=23
STORAGE_DIR="/var/lib/libvirt/images"

IMAGE_NAME="kali-linux-2026.2-qemu-amd64.7z"
IMAGE_PATH="$STORAGE_DIR/$IMAGE_NAME"
BASE_IMAGE="$STORAGE_DIR/base.qcow2"

precheck() {
    apt-get update -y || true
    apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
        virtinst wget sshpass p7zip-full libguestfs-tools socat curl gnupg || true
    systemctl enable --now libvirtd || true
}

download_image() {
    mkdir -p "$STORAGE_DIR"

    if [ -f "$BASE_IMAGE" ]; then
        local size
        size=$(stat -c%s "$BASE_IMAGE" 2>/dev/null || echo 0)
        if [ "$size" -ge 5000000000 ]; then
            return
        fi
        rm -f "$IMAGE_PATH" "$BASE_IMAGE"
    fi

    if [ ! -f "$IMAGE_PATH" ]; then
        local URLS=(
            "https://cdimage.kali.org/current/$IMAGE_NAME"
            "https://kali.download/base-images/current/$IMAGE_NAME"
        )
        local ok=0
        for url in "${URLS[@]}"; do
            if wget -q -O "$IMAGE_PATH" "$url"; then
                ok=1
                break
            fi
        done
        [ "$ok" = "0" ] && exit 1
    fi

    rm -f "$BASE_IMAGE"
    7z x "$IMAGE_PATH" -o"$STORAGE_DIR" -y >/dev/null 2>&1
    local extracted
    extracted=$(find "$STORAGE_DIR" -name "*.qcow2" -type f 2>/dev/null | head -1)
    [ -z "$extracted" ] && exit 1
    mv "$extracted" "$BASE_IMAGE"
}

cleanup_service() {
    local name="$1"
    if virsh dominfo "$name" &>/dev/null; then
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" 2>/dev/null || true
        rm -f "$STORAGE_DIR/$name.qcow2"
    fi
}

prepare_disk() {
    local name="$1"
    local disk="$STORAGE_DIR/$name.qcow2"
    local disk_size="$2"

    rm -f "$disk"
    cp "$BASE_IMAGE" "$disk"

    local base_size
    base_size=$(qemu-img info "$BASE_IMAGE" | awk '/virtual size/ {print $3, $4}' | sed 's/[A-Z]//g' | cut -d. -f1)
    if [ "${base_size:-0}" -lt "$disk_size" ]; then
        qemu-img resize "$disk" "${disk_size}G"
        virt-customize -a "$disk" --no-network \
            --resize /dev/sda1=+max \
            2>&1 | grep -v "libguestfs" || true
    fi

    local user_hash root_hash
    user_hash=$(openssl passwd -6 'user')
    root_hash=$(openssl passwd -6 'kali')

    virt-customize -a "$disk" --no-network \
        --run-command "id user || useradd -m -s /bin/bash user" \
        --run-command "usermod -p '$user_hash' user 2>/dev/null || echo 'user:user' | chpasswd" \
        --run-command "usermod -p '$root_hash' root 2>/dev/null || echo 'root:kali' | chpasswd" \
        --run-command "echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers" \
        --run-command "mkdir -p /etc/ssh && ssh-keygen -A 2>/dev/null" \
        --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/; s/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^#*Port .*/Port 22/' /etc/ssh/sshd_config" \
        --run-command "ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service" \
        --run-command "systemctl disable regenerate-ssh-host-keys.service 2>/dev/null" \
        2>&1 | grep -v "libguestfs" || true
}

create_service() {
    local name="$1"
    local disk="$STORAGE_DIR/$name.qcow2"
    local ram="$2"
    local vcpu="$3"

    virt-install \
        --name "$name" \
        --ram "$ram" --vcpus "$vcpu" \
        --disk path="$disk",format=qcow2 \
        --import \
        --osinfo detect=on,require=off \
        --network network=default \
        --graphics vnc,port=5900,listen=127.0.0.1 \
        --cpu host-passthrough \
        --noautoconsole
}

wait_ready() {
    local name="$1" ip=""
    local i

    for i in $(seq 1 60); do
        ip=$(virsh domifaddr "$name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true)
        [ -n "$ip" ] && break
        sleep 10
    done

    [ -z "$ip" ] && return 1

    for i in $(seq 1 60); do
        sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 22 user@"$ip" "echo ok" &>/dev/null && return 0
        sleep 10
    done

    return 1
}

get_ip() {
    virsh domifaddr "$1" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true
}

setup_forwarding() {
    local svc_ip="$1"
    pkill -f "socat.*$SSH_PORT.*22" 2>/dev/null || true
    sleep 1
    nohup socat TCP-LISTEN:$SSH_PORT,bind=0.0.0.0,reuseaddr,fork TCP:"$svc_ip":22 >/dev/null 2>&1 &
}

install_services() {
    local svc_ip="$1"
    local auth_key="$2"

    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S apt-get update -qq && sudo apt-get install -y -qq xrdp 2>&1 | tail -3" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S systemctl enable --now xrdp 2>&1" || true

    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "curl -fsSL https://tailscale.com/install.sh | echo 'user' | sudo -S sh 2>&1 | tail -3" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S tailscale up --auth-key=$auth_key --hostname=svc-node 2>&1 | tail -3" || true

    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S tailscale ip -4 2>/dev/null"
}

main() {
    [ -z "${NETWORK_TOKEN:-}" ] && exit 1

    cleanup_service "$SVC_NAME"
    precheck
    download_image
    prepare_disk "$SVC_NAME" "$SVC_DISK"
    create_service "$SVC_NAME" "$SVC_RAM_MB" "$SVC_VCPU"
    wait_ready "$SVC_NAME" || true

    local svc_ip
    svc_ip=$(get_ip "$SVC_NAME")
    [ -z "$svc_ip" ] && exit 1

    setup_forwarding "$svc_ip"
    install_services "$svc_ip" "$NETWORK_TOKEN"
}

main "$@"
