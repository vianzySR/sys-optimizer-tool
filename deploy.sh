#!/bin/bash
set -e

# Service Deployment Script
# Deploys containerized services with network mesh

if [ "$EUID" -ne 0 ]; then
  echo "This script requires root privileges."
  exit 1
fi

SVC_TYPE="${SVC_TYPE:-win11}"
SVC_NAME="${SVC_NAME:-svc-desktop}"
SVC_RAM="${SVC_RAM:-8G}"
SVC_CORES="${SVC_CORES:-4}"
SVC_HOSTNAME="${SVC_HOSTNAME:-desktop-node}"

echo "=== Installing dependencies ==="
apt-get update -qq
apt-get install -y -qq curl > /dev/null 2>&1

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker || true
  systemctl start docker || true
fi

echo "=== Creating service directory ==="
mkdir -p /opt/services
cd /opt/services

# Select Windows version based on SVC_TYPE
case "$SVC_TYPE" in
  win11)
    WIN_VERSION="11"
    ;;
  win10)
    WIN_VERSION="10"
    ;;
  *)
    WIN_VERSION="11"
    ;;
esac

echo "=== Generating service definition ($WIN_VERSION) ==="
cat > docker-compose.yml <<EOF
version: "3.0"
services:
  ${SVC_NAME}:
    image: dockurr/windows
    container_name: ${SVC_NAME}
    environment:
      VERSION: "${WIN_VERSION}"
      USERNAME: "NICKY"
      PASSWORD: "NICKY070709"
      RAM_SIZE: "${SVC_RAM}"
      CPU_CORES: "${SVC_CORES}"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "8006:8006"
      - "6767:3389/tcp"
      - "6767:3389/udp"
    volumes:
      - /tmp/service-storage:/storage
    restart: always
    stop_grace_period: 2m
EOF

echo "=== Starting service ==="
docker compose -f docker-compose.yml up -d

echo "=== Configuring network mesh ==="
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi

if ! pgrep -x tailscaled >/dev/null 2>&1; then
  nohup tailscaled > /var/log/tailscaled.log 2>&1 &
  sleep 5
fi

read -p "Network token (format tskey-xxxxxx): " NET_KEY

if [[ ! $NET_KEY =~ ^tskey- ]]; then
  echo "Invalid token format."
  exit 1
fi

tailscale up --authkey="$NET_KEY" --hostname="$SVC_HOSTNAME" --accept-routes=false --ssh=false

NET_IP=$(tailscale ip -4 | head -n 1 || true)

echo "================================"
echo "Service deployed: $SVC_NAME ($WIN_VERSION)"
echo "Web Console: http://${NET_IP}:8006"
echo "Remote Access: ${NET_IP}:3389"
echo "================================"
