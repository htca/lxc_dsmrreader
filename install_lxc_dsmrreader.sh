#!/usr/bin/env bash
set -euo pipefail

# ---------------------- COLORS ----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

trap 'error "Script aborted unexpectedly."' ERR

clear
echo -e "${GREEN}=== DSMR-reader v6 Proxmox 9 LXC Helper ===${NC}"
echo

# ---------------------- AUTO CTID ----------------------
CTID=$(pvesh get /cluster/nextid || { error "Unable to get next CTID"; exit 1; })
HOSTNAME="dsmr"
MEMORY=1024
DISK=8
BRIDGE="vmbr0"

info "Using CTID: ${YELLOW}$CTID${NC}"
echo

# ---------------------- TEMPLATE DETECTION ----------------------
info "Checking for Debian LXC templates..."

EXISTING_TEMPLATE=$(pveam list local \
    | awk '/debian-.*amd64/ {print $1}' \
    | sed 's|local:vztmpl/||' \
    | sort -V \
    | tail -n 1)

if [[ -n "$EXISTING_TEMPLATE" ]]; then
    ok "Found existing template: ${YELLOW}$EXISTING_TEMPLATE${NC}"
else
    warn "No local Debian template found. Detecting latest available..."

    LATEST_TEMPLATE=$(pveam available \
        | awk '/debian-.*amd64/ {print $2}' \
        | sort -V \
        | tail -n 1)

    if [[ -z "$LATEST_TEMPLATE" ]]; then
        error "Could not detect any Debian templates from pveam."
        exit 1
    fi

    info "Downloading template: ${YELLOW}$LATEST_TEMPLATE${NC}"
    pveam download local "$LATEST_TEMPLATE" || { error "Template download failed"; exit 1; }
    EXISTING_TEMPLATE="$LATEST_TEMPLATE"
fi

TEMPLATE="local:vztmpl/$EXISTING_TEMPLATE"
info "Using template: ${YELLOW}$TEMPLATE${NC}"
echo

# ---------------------- CONNECTION METHOD ----------------------
echo -e "${CYAN}Select P1 connection method:${NC}"
echo -e "  ${YELLOW}1)${NC} USB device passthrough"
echo -e "  ${YELLOW}2)${NC} ser2net (TCP)"
read -rp "$(echo -e "${CYAN}Enter choice (1 or 2): ${NC}")" METHOD
echo

if [[ "$METHOD" == "1" ]]; then
    info "Detecting USB serial devices..."
    echo

    USB_DEVICES=()
    INDEX=1

    for dev in /dev/serial/by-id/*; do
        [[ -e "$dev" ]] || continue
        TYPE=$(udevadm info -q property -n "$dev" | grep ID_MODEL= | cut -d= -f2)
        BASENAME=$(basename "$dev")
        echo -e "  ${YELLOW}$INDEX)${NC} $BASENAME  —  ${CYAN}$TYPE${NC}"
        USB_DEVICES+=("$BASENAME")
        INDEX=$((INDEX+1))
    done

    if [[ ${#USB_DEVICES[@]} -eq 0 ]]; then
        error "No USB serial devices found."
        exit 1
    fi

    echo
    read -rp "$(echo -e "${CYAN}Select a device (1-${#USB_DEVICES[@]}): ${NC}")" CHOICE
    CHOICE=$((CHOICE-1))

    if [[ $CHOICE -lt 0 || $CHOICE -ge ${#USB_DEVICES[@]} ]]; then
        error "Invalid selection"
        exit 1
    fi

    USBNAME="${USB_DEVICES[$CHOICE]}"
    USBDEV="/dev/serial/by-id/$USBNAME"

    ok "Selected USB device: ${YELLOW}$USBDEV${NC}"
    echo

elif [[ "$METHOD" == "2" ]]; then
    read -rp "$(echo -e "${CYAN}Enter ser2net host: ${NC}")" SER2NET_HOST
    read -rp "$(echo -e "${CYAN}Enter ser2net port: ${NC}")" SER2NET_PORT
    echo
else
    error "Invalid choice"
    exit 1
fi

# ---------------------- CREATE LXC ----------------------
info "Creating LXC ${YELLOW}$CTID${NC}..."

pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores 2 \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "local-lvm:$DISK" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 || { error "LXC creation failed"; exit 1; }

pct set "$CTID" -onboot 1
pct set "$CTID" -mp0 "/dev/fuse,mp=/dev/fuse"

# Proxmox 9 raw LXC config
pct set "$CTID" -raw "lxc.apparmor.profile=unconfined"
pct set "$CTID" -raw "lxc.cap.drop="

# USB passthrough
if [[ "$METHOD" == "1" ]]; then
    pct set "$CTID" -device0 "path=$USBDEV"
fi

pct start "$CTID" || { error "Failed to start container"; exit 1; }
sleep 5
ok "LXC ${YELLOW}$CTID${NC} created and started."
echo

# ---------------------- INSTALL DSMR-READER ----------------------
info "Installing DSMR-reader inside container..."

pct exec "$CTID" -- bash -c "
apt update &&
apt install -y podman podman-compose podman-docker uidmap git systemd &&
useradd dsmrreader --create-home &&
usermod -a -G dialout dsmrreader &&
loginctl enable-linger dsmrreader
" || { error "Failed to install base packages"; exit 1; }

ok "Base packages and user created."
echo

# ---------------------- DOWNLOAD COMPOSE FILES ----------------------
info "Downloading DSMR-reader compose files..."

pct exec "$CTID" -- bash -c "
sudo -u dsmrreader bash -c '
cd ~ &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.yml -O compose.yml &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.env -O compose.env
'
" || { error "Failed to download compose files"; exit 1; }

ok "Compose files downloaded."
echo

# ---------------------- CONFIGURE compose.env ----------------------
info "Configuring DSMR-reader connection mode..."

if [[ "$METHOD" == "1" ]]; then
    pct exec "$CTID" -- bash -c "
    sudo -u dsmrreader sed -i \
        -e 's|DSMRREADER_DATALOGGER_MODE=.*|DSMRREADER_DATALOGGER_MODE=serial|' \
        -e 's|DSMRREADER_DATALOGGER_SERIAL_PORT=.*|DSMRREADER_DATALOGGER_SERIAL_PORT=$USBDEV|' \
        ~/compose.env
    "
else
    pct exec "$CTID" -- bash -c "
    sudo -u dsmrreader sed -i \
        -e 's|DSMRREADER_DATALOGGER_MODE=.*|DSMRREADER_DATALOGGER_MODE=tcp|' \
        -e 's|DSMRREADER_DATALOGGER_TCP_HOST=.*|DSMRREADER_DATALOGGER_TCP_HOST=$SER2NET_HOST|' \
        -e 's|DSMRREADER_DATALOGGER_TCP_PORT=.*|DSMRREADER_DATALOGGER_TCP_PORT=$SER2NET_PORT|' \
        ~/compose.env
    "
fi

ok "compose.env configured."
echo

# ---------------------- START DSMR-READER ----------------------
info "Starting DSMR-reader containers..."

pct exec "$CTID" -- bash -c "
sudo -u dsmrreader bash -c '
cd ~ &&
podman-compose up -d
'
" || { error "Failed to start DSMR-reader containers"; exit 1; }

ok "DSMR-reader containers started."
echo

echo -e "${GREEN}------------------------------------------------------------${NC}"
echo -e "${GREEN}DSMR-reader LXC created and installed.${NC}"
echo -e "  ${CYAN}Container ID:${NC} ${YELLOW}$CTID${NC}"
echo -e "  ${CYAN}Connection method:${NC} ${YELLOW}$([[ \"$METHOD\" == \"1\" ]] && echo USB || echo ser2net)${NC}"
echo -e "${GREEN}------------------------------------------------------------${NC}"
echo -e "Access DSMR-reader at: ${YELLOW}http://<container-ip>:7777${NC}"
echo -e "${GREEN}------------------------------------------------------------${NC}"
