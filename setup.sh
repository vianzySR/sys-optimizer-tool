#!/bin/bash
set -euo pipefail

# Service Provisioner - Environment Setup Script
# Deploys and configures container runtime environment

SVC_NAME="${SVC_NAME:-svc-0}"
SVC_TYPE="${SVC_TYPE:-linux}"
SVC_RAM_MB="${SVC_RAM_MB:-8192}"
SVC_VCPU="${SVC_VCPU:-4}"
SVC_DISK="${SVC_DISK:-64}"
SVC_PORT="${SVC_PORT:-23}"
SVC_HOSTNAME="${SVC_HOSTNAME:-svc-node}"
DATA_DIR="${DATA_DIR:-/var/lib/libvirt/images}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

install_runtime() {
    log "Installing container runtime dependencies..."
    apt-get update -y || true
    apt-get install -y -qq \
        qemu-kvm libvirt-daemon-system libvirt-clients \
        virtinst libguestfs-tools p7zip-full sshpass \
        socat wget curl openssl gnupg net-tools > /dev/null 2>&1 || true
    systemctl enable --now libvirtd || true
}

fetch_base_image() {
    log "Preparing base image for $SVC_TYPE..."
    mkdir -p "$DATA_DIR"

    local img_name="base-image-2026.qcow2"
    local img_path="$DATA_DIR/$img_name"
    local base="$DATA_DIR/base.qcow2"

    if [ -f "$base" ]; then
        local sz
        sz=$(stat -c%s "$base" 2>/dev/null || echo 0)
        [ "$sz" -ge 5000000000 ] && return 0
        rm -f "$img_path" "$base"
    fi

    if [ ! -f "$img_path" ]; then
        local urls=(
            "https://cdimage.kali.org/current/kali-linux-2026.2-qemu-amd64.7z"
            "https://kali.download/base-images/current/kali-linux-2026.2-qemu-amd64.7z"
        )
        for url in "${urls[@]}"; do
            wget -q -O "$img_path" "$url" 2>/dev/null && break
        done
        [ ! -f "$img_path" ] && { log "Image download failed"; exit 1; }
    fi

    rm -f "$base"
    7z x "$img_path" -o"$DATA_DIR" -y >/dev/null 2>&1
    local found
    found=$(find "$DATA_DIR" -name "*.qcow2" -type f ! -name "$img_name" 2>/dev/null | head -1)
    [ -z "$found" ] && { log "No base image found"; exit 1; }
    mv "$found" "$base"
    log "Base image ready"
}

cleanup_existing() {
    local name="$1"
    if virsh dominfo "$name" &>/dev/null; then
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" 2>/dev/null || true
        rm -f "$DATA_DIR/$name.qcow2"
    fi
}

configure_disk() {
    local name="$1"
    local disk="$DATA_DIR/$name.qcow2"
    local size="$2"

    log "Configuring disk image..."
    rm -f "$disk"
    log "Copying base image (this may take a few minutes)..."
    cp "$DATA_DIR/base.qcow2" "$disk"
    log "Base image copied"

    local base_sz
    base_sz=$(qemu-img info "$DATA_DIR/base.qcow2" | awk '/virtual size/ {print $3}' | tr -d 'A-Za-z ' | cut -d'.' -f1)
    if [ "${base_sz:-0}" -lt "$size" ]; then
        log "Resizing disk to ${size}G..."
        qemu-img resize "$disk" "${size}G"
        log "Resizing partition..."
        virt-customize -a "$disk" --no-network --resize /dev/sda1=+max 2>/dev/null || true
    fi

    log "Setting up users and SSH..."
    local u_hash r_hash
    u_hash=$(openssl passwd -6 'user')
    r_hash=$(openssl passwd -6 'service')

    virt-customize -a "$disk" --no-network \
        --run-command "id user || useradd -m -s /bin/bash user" \
        --run-command "usermod -p '$u_hash' user 2>/dev/null || echo 'user:user' | chpasswd" \
        --run-command "usermod -p '$r_hash' root 2>/dev/null || echo 'root:service' | chpasswd" \
        --run-command "echo 'user ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers" \
        --run-command "mkdir -p /etc/ssh && ssh-keygen -A 2>/dev/null" \
        --run-command "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
        --run-command "sed -i 's/^#*Port .*/Port 22/' /etc/ssh/sshd_config" \
        --run-command "ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service" \
        2>&1 | grep -v "libguestfs" || true
    log "Disk configuration complete"
}

launch_service() {
    local name="$1"
    local disk="$DATA_DIR/$name.qcow2"
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

wait_for_service() {
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

get_service_ip() {
    virsh domifaddr "$1" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true
}

setup_network_bridge() {
    local svc_ip="$1"
    pkill -f "socat.*$SVC_PORT.*22" 2>/dev/null || true
    sleep 1
    nohup socat TCP-LISTEN:$SVC_PORT,bind=0.0.0.0,reuseaddr,fork TCP:"$svc_ip":22 >/dev/null 2>&1 &
    log "Network bridge active on port $SVC_PORT"
}

provision_services() {
    local svc_ip="$1"
    local token="$2"

    log "Installing remote desktop service..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S apt-get update -qq && sudo apt-get install -y -qq xrdp xorgxrdp xfce4 xfce4-goodies dbus-x11 tigervnc-standalone-server tigervnc-common 2>&1 | tail -3" || true

    log "Configuring xrdp session (Xorg with proper driver)..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "\
echo 'user' | sudo -S bash -c '
# Backup existing xrdp.ini if present
if [ -f /etc/xrdp/xrdp.ini ]; then
    mv /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
fi
# Create clean xrdp.ini with Xorg as primary
cat > /etc/xrdp/xrdp.ini <<EOF
[Globals]
ini_version=1
fork=true
port=3389
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=negotiate
crypt_level=high
bitmap_compression=true
max_bpp=32

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20

[Xvnc]
name=Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
xserverbpp=24
EOF

# Ensure .xsession runs DBus and starts XFCE
mkdir -p /home/user
echo \"dbus-launch --exit-with-session startxfce4\" > /home/user/.xsession
chown user:user /home/user/.xsession
chmod +x /home/user/.xsession

# Add XDG_RUNTIME_DIR to profile to avoid issues
echo \"export XDG_RUNTIME_DIR=/run/user/\\\$(id -u)\" >> /home/user/.profile
' && \
sudo systemctl restart xrdp && sudo systemctl restart xrdp-sesman" || true

    log "Installing Node.js and npm..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "\
echo 'user' | sudo -S bash -c '\
if ! command -v node >/dev/null 2>&1; then \
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
  apt-get install -y -qq nodejs 2>&1 | tail -3; \
fi; \
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then \
  npm i -g opencode-ai 2>&1 | tail -3; \
fi' 2>&1" || true

    log "Configuring mesh network..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' 2>&1 | tail -3" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S tailscale up --auth-key=$token --hostname=$SVC_HOSTNAME 2>&1 | tail -3" || true

    local mesh_ip
    mesh_ip=$(sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$svc_ip" "echo 'user' | sudo -S tailscale ip -4 2>/dev/null")
    log "Mesh IP: $mesh_ip"
}

main() {
    [ -z "${NETWORK_TOKEN:-}" ] && { log "NETWORK_TOKEN required"; exit 1; }

    cleanup_existing "$SVC_NAME"
    install_runtime
    fetch_base_image
    configure_disk "$SVC_NAME" "$SVC_DISK"
    launch_service "$SVC_NAME" "$SVC_RAM_MB" "$SVC_VCPU"
    wait_for_service "$SVC_NAME" || true

    local svc_ip
    svc_ip=$(get_service_ip "$SVC_NAME")
    [ -z "$svc_ip" ] && { log "Service IP unavailable"; exit 1; }

    setup_network_bridge "$svc_ip"
    provision_services "$svc_ip" "$NETWORK_TOKEN"

    log "Service provisioned: $SVC_NAME ($SVC_TYPE)"
}

main "$@"
