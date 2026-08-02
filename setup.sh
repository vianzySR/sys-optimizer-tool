#!/bin/bash
set -euo pipefail

# Service Provisioner - Environment Setup Script
# Deploys and configures container runtime environment

SVC_NAME="${SVC_NAME:-svc-0}"
SVC_TYPE="${SVC_TYPE:-linux}"
SVC_RAM_MB="${SVC_RAM_MB:-12288}"
SVC_VCPU="${SVC_VCPU:-2}"
SVC_DISK="${SVC_DISK:-64}"
SVC_PORT="${SVC_PORT:-23}"
SVC_HOSTNAME="${SVC_HOSTNAME:-svc-node}"
SVC_USER="${SVC_USER:-user}"
SVC_PASS="${SVC_PASS:-user}"
SVC_ROOT_PASS="${SVC_ROOT_PASS:-root}"
DATA_DIR="${DATA_DIR:-/var/lib/libvirt/images}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

install_runtime() {                                                        log "Installing container runtime dependencies..."
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
    u_hash=$(openssl passwd -6 "$SVC_PASS")
    r_hash=$(openssl passwd -6 "$SVC_ROOT_PASS")

    virt-customize -a "$disk" --no-network \
        --run-command "id $SVC_USER || useradd -m -s /bin/bash $SVC_USER" \
        --run-command "usermod -p '$u_hash' $SVC_USER 2>/dev/null || echo '$SVC_USER:$SVC_PASS' | chpasswd" \
        --run-command "usermod -p '$r_hash' root 2>/dev/null || echo 'root:$SVC_ROOT_PASS' | chpasswd" \
        --run-command "echo '$SVC_USER ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers" \
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
        sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 22 "$SVC_USER"@"$ip" "echo ok" &>/dev/null && return 0
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
    log "SSH bridge active on port $SVC_PORT -> $svc_ip:22"
    log "RDP is Tailscale-only (firewalled inside the VM); connect to the VM's mesh IP on port 3389"
}

provision_services() {
    local svc_ip="$1"
    local token="$2"

    log "Installing remote desktop service + build deps for Xorg backend..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S bash -c '
set -e
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xrdp xfce4 xfce4-goodies dbus-x11 tigervnc-standalone-server tigervnc-common nftables build-essential pkg-config autoconf automake libtool xserver-xorg-dev libx11-dev libxfixes-dev libxrandr-dev libepoxy-dev libpixman-1-dev curl 2>&1 | tail -2
' 2>&1" || true

    log "Building xorgxrdp 0.10.5 from source (Kali ships no package; its xrdp Breaks old xorgxrdp)..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S bash -c '
set -e
cd /tmp
rm -rf xorgxrdp-0.10.5 xorgxrdp-0.10.5.tar.gz
curl -fsSL -o xorgxrdp-0.10.5.tar.gz https://github.com/neutrinolabs/xorgxrdp/releases/download/v0.10.5/xorgxrdp-0.10.5.tar.gz
tar xzf xorgxrdp-0.10.5.tar.gz
cd xorgxrdp-0.10.5
./bootstrap >/dev/null
./configure --prefix=/usr >/dev/null
make -j2 >/dev/null
mkdir -p /usr/lib/xorg/modules/drivers /usr/lib/xorg/modules/input /etc/X11/xrdp
cp -a xrdpdev/.libs/xrdpdev_drv.so /usr/lib/xorg/modules/drivers/
cp -a xrdpkeyb/.libs/xrdpkeyb_drv.so /usr/lib/xorg/modules/input/
cp -a xrdpmouse/.libs/xrdpmouse_drv.so /usr/lib/xorg/modules/input/
cp -a module/.libs/libxorgxrdp.so /usr/lib/xorg/modules/
cp -a xrdpdev/xorg.conf /etc/X11/xrdp/xorg.conf
rm -rf /tmp/xorgxrdp-0.10.5 /tmp/xorgxrdp-0.10.5.tar.gz
' 2>&1" || true

    log "Configuring xrdp session (Xorg backend + Xvnc fallback)..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "\
echo '$SVC_PASS' | sudo -S bash -c '
set -e
# Backup existing xrdp.ini if present
if [ -f /etc/xrdp/xrdp.ini ]; then
    mv /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak
fi
# Clean xrdp.ini: Xorg backend (xorgxrdp 0.10.5 built from source) as default,
# with Xvnc/tigervnc as fallback. RDP is restricted by nftables to tailscale0 only.
cat > /etc/xrdp/xrdp.ini <<EOF
[Globals]
ini_version=1
fork=true
port=3389
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=negotiate
crypt_level=none
bitmap_compression=true
max_bpp=32
allow_channels=true
certificate=/etc/xrdp/cert.pem
key_file=/etc/xrdp/key.pem

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
xserverbpp=32

[Channels]
rdpdr=true
rdpsnd=true
drdynvc=true
cliprdr=true
rail=true
xrdpvr=true
EOF

# TLS certificate for xrdp (snakeoil symlinks are created by the package;
# fall back to a self-signed cert if they are missing)
if [ ! -f /etc/xrdp/cert.pem ] || [ ! -f /etc/xrdp/key.pem ]; then
    openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
        -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem \
        -subj \"/CN=$SVC_HOSTNAME\" >/dev/null 2>&1
fi
# Normalize cert/key ownership so xrdp can always read them (avoids
# "Cannot accept TLS" handshake errors and fallback to weak security)
chown root:ssl-cert /etc/xrdp/cert.pem /etc/xrdp/key.pem 2>/dev/null || true
chmod 644 /etc/xrdp/cert.pem
chmod 640 /etc/xrdp/key.pem
test -r /etc/xrdp/cert.pem && test -r /etc/xrdp/key.pem \
    || { echo \"FATAL: xrdp TLS key unreadable\"; exit 1; }

# Ensure .xsession runs DBus and starts XFCE
mkdir -p /home/$SVC_USER
echo \"dbus-launch --exit-with-session startxfce4\" > /home/$SVC_USER/.xsession
chown $SVC_USER:$SVC_USER /home/$SVC_USER/.xsession
chmod +x /home/$SVC_USER/.xsession

# Add XDG_RUNTIME_DIR to profile to avoid issues
echo \"export XDG_RUNTIME_DIR=/run/user/\\\$(id -u)\" >> /home/$SVC_USER/.profile

# Create the runtime dir with correct ownership (missing dir = session errors)
mkdir -p /run/user/$(id -u $SVC_USER)
chown $SVC_USER:$SVC_USER /run/user/$(id -u $SVC_USER)
chmod 700 /run/user/$(id -u $SVC_USER)

# Disable XFCE compositing (big CPU saving on software-rendered Xvnc)
mkdir -p /home/$SVC_USER/.config/xfce4/xfwm4
cat > /home/$SVC_USER/.config/xfce4/xfwm4/xfwm4.xml <<XEOF
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<channel name=\"xfwm4\" version=\"1.0\">
  <property name=\"general\" type=\"empty\">
    <property name=\"use_compositing\" type=\"bool\" value=\"false\"/>
  </property>
</channel>
XEOF
chown -R $SVC_USER:$SVC_USER /home/$SVC_USER/.config

# Keep disconnected sessions alive for 4h so reconnects RESUME the same
# session (apps stay open), then auto-clean them to avoid pile-up
sed -i "s/^KillDisconnected=false/KillDisconnected=true/" /etc/xrdp/sesman.ini
sed -i "s/^DisconnectedTimeLimit=.*/DisconnectedTimeLimit=14400/" /etc/xrdp/sesman.ini

# Free RAM/CPU: headless RDP-only VM has no use for a local display manager
systemctl disable --now lightdm ModemManager colord 2>/dev/null || true

# zram swap (4G compressed) for RAM headroom
cat > /usr/local/sbin/zram-setup.sh <<ZEOF
#!/bin/bash
modprobe zram
if [ -e /sys/block/zram0/disksize ]; then
    swapoff /dev/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
fi
echo 4G > /sys/block/zram0/disksize
/sbin/mkswap /dev/zram0
/sbin/swapon /dev/zram0
ZEOF
chmod +x /usr/local/sbin/zram-setup.sh
cat > /etc/systemd/system/zram-swap.service <<ZEOF
[Unit]
Description=Set up zram swap
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-setup.sh
ExecStop=/usr/sbin/swapoff /dev/zram0

[Install]
WantedBy=multi-user.target
ZEOF
systemctl daemon-reload
systemctl enable --now zram-swap

# Self-healing: auto-restart xrdp/xrdp-sesman if they ever crash
mkdir -p /etc/systemd/system/xrdp.service.d /etc/systemd/system/xrdp-sesman.service.d
printf '[Service]\nRestart=on-failure\nRestartSec=3\n' > /etc/systemd/system/xrdp.service.d/restart.conf
printf '[Service]\nRestart=on-failure\nRestartSec=3\n' > /etc/systemd/system/xrdp-sesman.service.d/restart.conf
systemctl daemon-reload

# Rotate xrdp logs so DEBUG output never fills the disk
cat > /etc/logrotate.d/xrdp <<LROT
/var/log/xrdp*.log /home/*/.xorgxrdp.*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LROT

# Clear stale X sockets/locks that can block new sessions (provision-time only)
rm -rf /tmp/.X11-unix /tmp/.X11-lock 2>/dev/null || true
mkdir -p /tmp/.X11-unix /tmp/.X11-lock
chmod 1777 /tmp/.X11-unix /tmp/.X11-lock

# Internal sanity check before restart
test -f /usr/lib/xorg/modules/drivers/xrdpdev_drv.so || { echo \"FATAL: xorgxrdp module missing\"; exit 1; }
' && \
sudo systemctl restart xrdp-sesman && sudo systemctl restart xrdp" || true

    log "Locking RDP to Tailscale interface only (nftables)..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S bash -c '
set -e
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority filter; policy accept;
    tcp dport 3389 iifname != \"tailscale0\" drop
  }
}
EOF
systemctl enable --now nftables
systemctl restart nftables
'" || true

    log "Verifying RDP listener and Tailscale-only rule inside the VM..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S bash -c '
set -e
systemctl is-active xrdp xrdp-sesman >/dev/null 2>&1 && echo \"PASS xrdp services active\" || echo \"FAIL xrdp services not active\"
test -f /usr/lib/xorg/modules/drivers/xrdpdev_drv.so && echo \"PASS xorgxrdp module present\" || echo \"FAIL xorgxrdp module missing\"
test -r /etc/xrdp/cert.pem && test -r /etc/xrdp/key.pem && echo \"PASS TLS cert/key readable\" || echo \"FAIL TLS cert/key unreadable\"
ss -tlnp 2>/dev/null | grep -q \":3389\" && echo \"PASS RDP listening\" || echo \"FAIL RDP not listening\"
nft list ruleset 2>/dev/null | grep -q \"3389\" && echo \"PASS firewall rule\" || echo \"FAIL firewall rule missing\"
'" || true

    log "Installing Node.js and npm..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "\
echo '$SVC_PASS' | sudo -S bash -c '\
set -e
if ! command -v node >/dev/null 2>&1; then \
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
  apt-get install -y -qq nodejs 2>&1 | tail -3; \
fi; \
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then \
  npm i -g opencode-ai 2>&1 | tail -3; \
fi' 2>&1" || true

    log "Configuring mesh network..."
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S bash -c 'curl -fsSL https://tailscale.com/install.sh | sh' 2>&1 | tail -3" || true
    sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S tailscale up --auth-key=$token --hostname=$SVC_HOSTNAME 2>&1 | tail -3" || true

    local mesh_ip
    mesh_ip=$(sshpass -p "$SVC_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "$SVC_USER"@"$svc_ip" "echo '$SVC_PASS' | sudo -S tailscale ip -4 2>/dev/null")
    log "Mesh IP: $mesh_ip"
    log "RDP (Tailscale-only): $mesh_ip:3389 (blocked on all other interfaces)"
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
