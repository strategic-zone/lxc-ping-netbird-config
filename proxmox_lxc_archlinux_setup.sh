#!/usr/bin/env sh
: <<HEADER
title       : proxmox_lxc_archlinux_setup.sh
description : Automated setup script for Arch Linux LXC container with Docker, Netbird and Flux
author      : Strategic Zone
email       : ts@strategic.zone
date        : 2024-12-23
version     : 1.0
features    : - LXC container with Arch Linux
             - Docker and Docker Compose
             - FluxCD for GitOps
             - SSH port customization
             - VLAN support
             - Auto ID assignment
             - GitHub SSH key
             - LXC features (nesting, fuse, mknod)
notes       : Run with env vars:
             NETBIRD_SETUP_KEY=key \
             GITHUB_TOKEN=token \
             GITHUB_USER=username \
             GITHUB_REPO=repo \
             ./proxmox_lxc_archlinux_setup.sh
=========================
HEADER

# Check required env vars
[ -z "$NETBIRD_SETUP_KEY" ] && echo "NETBIRD_SETUP_KEY required" && exit 1

# Variables
# Variables with defaults and env override
CONTAINER_NAME=${CONTAINER_NAME:-"ping-xxx"}
VLAN_ID=${VLAN_ID:-""}  # Empty by default
STORAGE=${STORAGE:-"local"}
RAM=${RAM:-2048}
SWAP=${SWAP:-1024}
DISK=${DISK:-10}
CORES=${CORES:-2}
TEMPLATE_PATH="/var/lib/vz/template/cache"
SSH_PORT=${SSH_PORT:-34522}
UNPRIVILEGED=${UNPRIVILEGED:-0}

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Function to get next available container ID
get_next_container_id() {
    local last_id=$(pvesh get /cluster/resources --type vm | grep -v qemu | grep -v "^NAME" | awk '{print $2}' | sed 's/lxc\///' | sort -n | tail -n1)
    if [ -z "$last_id" ]; then
        echo "100"
    else
        echo "$((last_id + 1))"
    fi
}

CONTAINER_ID=$(get_next_container_id)
echo -e "${GREEN}Next available ID will be: $CONTAINER_ID${NC}"

# Get the latest archlinux-base template
pveam update
TEMPLATE=$(pveam available | grep 'archlinux-base' | awk '{print $2}' | head -n 1)

if [ -z "$TEMPLATE" ]; then
    echo -e "${RED}Failed to find Arch Linux template${NC}"
    exit 1
fi

# Download template if not already present
if [ ! -f "$TEMPLATE_PATH/$(basename $TEMPLATE)" ]; then
    echo -e "${GREEN}Downloading template: $TEMPLATE${NC}"
    pveam download local $TEMPLATE
fi

# Prepare network configuration based on VLAN_ID
if [ -n "$VLAN_ID" ]; then
    NETWORK_CONF="name=eth0,bridge=vmbr0,ip=dhcp,tag=$VLAN_ID"
else
    NETWORK_CONF="name=eth0,bridge=vmbr0,ip=dhcp"
fi

# Create container
echo -e "${GREEN}Creating container...${NC}"
pct create $CONTAINER_ID "$TEMPLATE_PATH/$(basename $TEMPLATE)" \
    --hostname $CONTAINER_NAME \
    --features nesting=1,fuse=1,mknod=1 \
    --cores $CORES \
    --memory $RAM \
    --swap $SWAP \
    --storage $STORAGE \
    --net0 $NETWORK_CONF \
    --rootfs $STORAGE:$DISK \
    --unprivileged $UNPRIVILEGED \
    --cmode shell \
    --onboot 1 \
    --protection 1 \
    --start 1

echo -e "${GREEN}Adding LXC specific configurations...${NC}"
cat >> "/etc/pve/lxc/${CONTAINER_ID}.conf" << EOF

# Custom configurations
lxc.apparmor.profile: unconfined
lxc.cgroup.devices.allow: a
lxc.cap.drop: 
EOF

sleep 15

# Initialize pacman keyring and update system
echo -e "${GREEN}Initializing pacman keyring and updating system...${NC}"
pct exec $CONTAINER_ID -- bash -c '
    pacman-key --init
    pacman-key --populate
    pacman -Sy --noconfirm archlinux-keyring
    pacman -Syu --noconfirm
'

# Install required packages including Flux
echo -e "${GREEN}Installing required packages...${NC}"
pct exec $CONTAINER_ID -- bash -c '
    pacman -S --noconfirm openssh python docker docker-compose zsh neovim net-tools git
'

# Configure SSH port
echo -e "${GREEN}Configuring SSH...${NC}"
pct exec $CONTAINER_ID -- bash -c "
    mkdir -p /etc/ssh/sshd_config.d
    echo 'Port ${SSH_PORT}' > /etc/ssh/sshd_config.d/sz-ssh-config-config.conf
    systemctl enable --now sshd
"

# Setup SSH key
echo -e "${GREEN}Setting up SSH key...${NC}"
pct exec $CONTAINER_ID -- bash -c '
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    curl -s https://github.com/ts-sz.keys > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
'

# Enable Docker
echo -e "${GREEN}Enabling Docker...${NC}"
pct exec $CONTAINER_ID -- systemctl enable --now docker

# Setup Netbird compose
echo -e "${GREEN}Setting up Netbird...${NC}"
pct exec $CONTAINER_ID -- bash -c "
    mkdir -p /srv/dockers/services/netbird
    cat > /srv/dockers/services/netbird/compose.yml << EOF
---
services:
  netbird:
    image: netbirdio/netbird:latest
    container_name: ${CONTAINER_NAME}
    hostname: ${CONTAINER_NAME}
    network_mode: host
    restart: always
    privileged: true
    cap_add:
      - NET_ADMIN
      - NET_RAW
    environment:
      TZ: Europe/Paris
      NB_SETUP_KEY: ${NETBIRD_SETUP_KEY}
    volumes:
      - ./netbird-client:/etc/netbird
EOF
"

# Start Netbird
echo -e "${GREEN}Starting Netbird...${NC}"
pct exec $CONTAINER_ID -- bash -c "
    cd /srv/dockers/services/netbird
    docker compose pull
    docker compose up -d
"

# Get container IP
IP=$(pct exec $CONTAINER_ID -- ip -4 addr show eth0 | grep -oP 'inet \K[\d.]+')

echo -e "${GREEN}Setup complete!${NC}"
echo -e "${GREEN}Container ID: $CONTAINER_ID${NC}"
echo -e "${GREEN}Container Name: $CONTAINER_NAME${NC}"
echo -e "${GREEN}Container IP: $IP${NC}"
echo -e "${GREEN}SSH Port: $SSH_PORT${NC}"
[ -n "$VLAN_ID" ] && echo -e "${GREEN}VLAN ID: $VLAN_ID${NC}"
echo -e "${GREEN}Flux is watching: $REPO_URL${NC}"