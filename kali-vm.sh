#!/bin/bash
set -euo pipefail

VM_NAME="user1-vm"
VM_RAM_MB=8192    # 8GB RAM
VM_VCPU=2         # 2 Core
VM_DISK=64        # 64GB Disk
SSH_PORT=23       # SSH port untuk akses dari host
STORAGE_DIR="/var/lib/libvirt/images"

QEMU_7Z_NAME="kali-linux-2026.2-qemu-amd64.7z"
QEMU_7Z_PATH="$STORAGE_DIR/$QEMU_7Z_NAME"
BASE_IMAGE="$STORAGE_DIR/kali-base.qcow2"

log(){ echo "[$(date '+%H:%M:%S')] $*" >&2; }

precheck() {
    log "System precheck..."
    apt-get update -y || true
    apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients \
        virtinst wget sshpass p7zip-full libguestfs-tools novnc websockify socat curl wget gnupg || true
    systemctl enable --now libvirtd || true
}

download_qemu_image() {
    log "Checking QEMU image..."
    mkdir -p "$STORAGE_DIR"

    if [ -f "$BASE_IMAGE" ]; then
        local size
        size=$(stat -c%s "$BASE_IMAGE" 2>/dev/null || echo 0)
        if [ "$size" -ge 5000000000 ]; then
            log "Base image exists"
            return
        fi
        log "Image corrupt, re-downloading..."
        rm -f "$QEMU_7Z_PATH" "$BASE_IMAGE"
    fi

    if [ ! -f "$QEMU_7Z_PATH" ]; then
        local URLS=(
            "https://cdimage.kali.org/current/$QEMU_7Z_NAME"
            "https://kali.download/base-images/current/$QEMU_7Z_NAME"
        )
        local downloaded=0
        for url in "${URLS[@]}"; do
            log "Downloading $url"
            if wget -O "$QEMU_7Z_PATH" "$url"; then
                downloaded=1
                break
            fi
        done
        if [ "$downloaded" = "0" ]; then
            log "Download FAILED"
            exit 1
        fi
    fi

    log "Extracting QEMU image..."
    rm -f "$BASE_IMAGE"
    7z x "$QEMU_7Z_PATH" -o"$STORAGE_DIR" -y >/dev/null 2>&1
    # Find the extracted qcow2
    local extracted
    extracted=$(find "$STORAGE_DIR" -name "*.qcow2" -type f 2>/dev/null | head -1)
    if [ -z "$extracted" ]; then
        log "No qcow2 found in 7z"
        exit 1
    fi
    mv "$extracted" "$BASE_IMAGE"
    log "Base image ready: $BASE_IMAGE"
}

remove_existing_vm() {
    local name="$1"
    local disk="$STORAGE_DIR/$name.qcow2"
    
    if virsh dominfo "$name" &>/dev/null; then
        log "Removing existing VM: $name..."
        virsh destroy "$name" 2>/dev/null || true
        virsh undefine "$name" 2>/dev/null || true
        rm -f "$disk"
        log "$name removed"
    fi
}

prepare_vm_disk() {
    local name="$1"
    local disk="$STORAGE_DIR/$name.qcow2"
    local disk_size="$2"

    log "Preparing disk for $name (${disk_size}GB)..."
    
    # Remove old disk if exists
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

    log "$name disk ready (${disk_size}GB)"
}

create_vm() {
    local name="$1"
    local disk="$STORAGE_DIR/$name.qcow2"
    local ram="$2"
    local vcpu="$3"

    log "Creating VM: $name (RAM: ${ram}MB, vCPUs: ${vcpu}, Disk: ${VM_DISK}GB)"

    virt-install \
        --name "$name" \
        --ram "$ram" --vcpus "$vcpu" \
        --disk path="$disk",format=qcow2 \
        --import \
        --osinfo detect=on,require=off \
        --network network=default \
        --graphics vnc,port=5900,listen=0.0.0.0 \
        --cpu host-passthrough \
        --noautoconsole

    log "$name created and booting"
}

wait_vm_ready() {
    local name="$1" ip=""

    log "Waiting $name IP..."
    for i in {1..60}; do
        ip=$(virsh domifaddr "$name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true)
        [ -n "$ip" ] && { log "$name IP: $ip"; break; }
        sleep 10
    done

    if [ -z "$ip" ]; then
        log "FAILED: no IP for $name"
        virsh domifaddr "$name" 2>/dev/null || true
        return 1
    fi

    local ssh_ok=0
    log "Waiting $name SSH..."
    for i in {1..60}; do
        sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -p 22 user@"$ip" "echo ok" &>/dev/null && { ssh_ok=1; break; }
        sleep 10
    done

    if [ "$ssh_ok" = "0" ]; then
        log "WARNING: SSH not ready for $name"
        return 1
    fi
    log "$name SSH READY"

    log "Installing xrdp on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "echo 'user' | sudo -S apt-get update -qq && sudo apt-get install -y -qq xrdp 2>&1 | tail -3" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "echo 'user' | sudo -S systemctl enable --now xrdp 2>&1" || true
    log "$name xrdp ready"

    log "Installing Node.js, npm, and opencode-ai on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "echo 'user' | sudo -S apt-get install -y -qq npm nodejs 2>&1 | tail -5" || true
    
    log "Installing opencode-ai globally via npm..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "npm config set strict-ssl false && npm install -g opencode-ai 2>&1 | tail -10" || true
    
    log "$name Node.js, npm, and opencode-ai installed"

    log "Installing Google Chrome on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo apt-key add - && \
        sudo sh -c 'echo \"deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main\" >> /etc/apt/sources.list.d/google-chrome.list' && \
        sudo apt-get update -qq && sudo apt-get install -y -qq google-chrome-stable 2>&1 | tail -5" || true
    log "$name Google Chrome installed"

    log "Installing VS Code on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg && \
        sudo install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/ && \
        sudo sh -c 'echo \"deb [arch=amd64] https://packages.microsoft.com/repos/code stable main\" > /etc/apt/sources.list.d/vscode.list' && \
        sudo apt-get update -qq && sudo apt-get install -y -qq code 2>&1 | tail -5" || true
    log "$name VS Code installed"

    log "Installing Discord on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "wget -O /tmp/discord.deb \"https://discord.com/api/download?platform=linux&format=deb\" && \
        sudo dpkg -i /tmp/discord.deb 2>/dev/null || sudo apt-get install -f -y -qq && \
        sudo dpkg -i /tmp/discord.deb 2>/dev/null && rm -f /tmp/discord.deb" || true
    log "$name Discord installed"

    log "Installing Brevent on $name..."
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "echo 'user' | sudo -S apt-get install -y -qq adb android-tools-adb android-tools-fastboot 2>&1 | tail -5" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "wget -O /tmp/brevent.apk https://github.com/brevent/brevent/releases/latest/download/brevent.apk 2>/dev/null || \
        wget -O /tmp/brevent.apk https://github.com/brevent/brevent/releases/download/v0.4.6/brevent.apk" || true
    sshpass -p "user" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 user@"$ip" "mkdir -p ~/Downloads && cp /tmp/brevent.apk ~/Downloads/ 2>/dev/null || true" || true
    log "$name Brevent (ADB tools and APK) installed"
}

get_vm_ip() {
    local name="$1"
    virsh domifaddr "$name" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 || true
}

setup_port_forwarding() {
    local vm_ip tailscale_ip

    vm_ip=$(get_vm_ip "$VM_NAME")

    if [ -z "$vm_ip" ]; then
        log "WARNING: Could not get VM IP for port forwarding"
        return
    fi

    tailscale_ip=$(tailscale ip -4 2>/dev/null || true)
    local bind_ip="${tailscale_ip:-0.0.0.0}"

    # Kill existing processes
    pkill -f "socat.*3380.*3389" 2>/dev/null || true
    pkill -f "socat.*$SSH_PORT.*22" 2>/dev/null || true
    sleep 1

    # RDP forwarding
    nohup socat TCP-LISTEN:3380,bind="$bind_ip",reuseaddr,fork TCP:"$vm_ip":3389 >/dev/null 2>&1 &
    
    # SSH forwarding from port 23 to VM port 22
    nohup socat TCP-LISTEN:$SSH_PORT,bind="$bind_ip",reuseaddr,fork TCP:"$vm_ip":22 >/dev/null 2>&1 &

    log "Port forwarding:"
    log "  SSH: $bind_ip:$SSH_PORT -> $vm_ip:22 ($VM_NAME)"
    log "  RDP: $bind_ip:3380 -> $vm_ip:3389 ($VM_NAME)"
}

setup_novnc() {
    local bind_ip
    bind_ip=$(tailscale ip -4 2>/dev/null || echo "0.0.0.0")

    pkill -f "websockify.*6080" 2>/dev/null || true
    sleep 1

    nohup websockify --web /usr/share/novnc 6080 :5900 >/dev/null 2>&1 &

    log "noVNC: http://$bind_ip:6080/vnc.html ($VM_NAME)"
}

main() {
    log "START"

    # Remove existing VM if any
    remove_existing_vm "$VM_NAME"

    precheck
    download_qemu_image
    
    # Prepare disk with 64GB
    prepare_vm_disk "$VM_NAME" "$VM_DISK"
    
    # Create VM with 2 core, 8GB RAM
    create_vm "$VM_NAME" "$VM_RAM_MB" "$VM_VCPU"
    
    wait_vm_ready "$VM_NAME" || true
    
    setup_novnc
    setup_port_forwarding

    local ts
    ts=$(tailscale ip -4 2>/dev/null || echo "<host-ip>")
    
    log "========================================"
    log "DONE - VM Configuration:"
    log "VM: $VM_NAME"
    log "  vCPUs: $VM_VCPU cores"
    log "  RAM: $VM_RAM_MB MB (8GB)"
    log "  Disk: $VM_DISK GB"
    log "========================================"
    log "Connect:"
    log "  SSH:  ssh -p $SSH_PORT user@$ts  (password: user)"
    log "  RDP:  $ts:3380 ($VM_NAME)"
    log "  VNC:  http://$ts:6080/vnc.html ($VM_NAME)"
    log "========================================"
    log "Installed Applications:"
    log "  - Node.js & npm"
    log "  - opencode-ai (global)"
    log "  - Google Chrome"
    log "  - VS Code"
    log "  - Discord"
    log "  - Brevent (ADB tools + APK in ~/Downloads/)"
    log "========================================"
    log "SSH Command:"
    log "  ssh -p $SSH_PORT user@$ts"
    log "========================================"
    log "To test opencode-ai after login:"
    log "  opencode --help"
    log "========================================"
    log "To run Brevent:"
    log "  1. Enable USB debugging on Android"
    log "  2. Connect device: adb devices"
    log "  3. Install APK: adb install ~/Downloads/brevent.apk"
    log "========================================"
}

main "$@"
