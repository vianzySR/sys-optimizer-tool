#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "This script requires root privileges."
  exit 1
fi

apt-get update -qq
apt-get install -y -qq docker.io docker-compose curl > /dev/null 2>&1

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker || true
  systemctl start docker || true
fi

mkdir -p /opt/services
cd /opt/services

cat > docker-compose.yml <<'EOF'
version: "3.0"
services:
  worker:
    image: dockurr/windows
    container_name: worker
    environment:
      VERSION: "11"
      USERNAME: "admin"
      PASSWORD: "admin@123"
      RAM_SIZE: "8G"
      CPU_CORES: "4"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "8006:8006"
      - "3389:3389/tcp"
      - "3389:3389/udp"
    volumes:
      - /tmp/service-storage:/storage
    restart: always
    stop_grace_period: 2m
EOF

docker-compose -f docker-compose.yml up -d

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

tailscale up --authkey="$NET_KEY" --hostname="service-host" --accept-routes=false --ssh=false

NET_IP=$(tailscale ip -4 | head -n 1 || true)

echo "================================"
echo "Service deployed."
echo "Web Console: http://${NET_IP}:8006"
echo "Remote Access: ${NET_IP}:3389"
echo "================================"
