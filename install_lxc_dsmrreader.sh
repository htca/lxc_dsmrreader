#!/usr/bin/env bash
set -e

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------
CTID=120
HOSTNAME="dsmr"
MEMORY=1024
DISK=8
BRIDGE="vmbr0"

# ------------------------------------------------------------
# USER INPUT: USB or ser2net
# ------------------------------------------------------------
echo "Select P1 connection method:"
echo "1) USB device passthrough"
echo "2) ser2net (TCP)"
read -rp "Enter choice (1 or 2): " METHOD

if [[ "$METHOD" == "1" ]]; then
    echo "Available USB devices on Proxmox:"
    ls -l /dev/serial/by-id/ || true
    read -rp "Enter the full path of the USB device (e.g. /dev/ttyUSB0 or /dev/serial/by-id/...): " USBDEV
elif [[ "$METHOD" == "2" ]]; then
    read -rp "Enter ser2net host (e.g. 192.168.1.10): " SER2NET_HOST
    read -rp "Enter ser2net port (e.g. 2001): " SER2NET_PORT
else
    echo "Invalid choice"
    exit 1
fi

# ------------------------------------------------------------
# CREATE LXC
# ------------------------------------------------------------
echo "Creating LXC $CTID..."

pct create $CTID local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst \
    --hostname $HOSTNAME \
    --cores 2 \
    --memory $MEMORY \
    --swap 512 \
    --rootfs local-lvm:$DISK \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
    --features nesting=1,keyctl=1 \
    --unprivileged 1

# Allow Podman rootless
pct set $CTID -onboot 1
pct set $CTID -features nesting=1,keyctl=1
pct set $CTID -mp0 /dev/fuse,mp=/dev/fuse
pct set $CTID -lxc "lxc.apparmor.profile=unconfined"
pct set $CTID -lxc "lxc.cap.drop="

# USB passthrough
if [[ "$METHOD" == "1" ]]; then
    pct set $CTID -device0 "$USBDEV"
fi

pct start $CTID
sleep 5

# ------------------------------------------------------------
# INSTALL DSMR-READER INSIDE LXC
# ------------------------------------------------------------
echo "Installing DSMR-reader inside container..."

pct exec $CTID -- bash -c "
apt update &&
apt install -y podman podman-compose podman-docker uidmap git &&
useradd dsmrreader --create-home &&
usermod -a -G dialout dsmrreader &&
loginctl enable-linger dsmrreader
"

# ------------------------------------------------------------
# DOWNLOAD COMPOSE FILES
# ------------------------------------------------------------
pct exec $CTID -- bash -c "
sudo -u dsmrreader bash -c '
cd ~ &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.yml -O compose.yml &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.env -O compose.env
'
"

# ------------------------------------------------------------
# CONFIGURE compose.env
# ------------------------------------------------------------
if [[ "$METHOD" == "1" ]]; then
    # USB device
    pct exec $CTID -- bash -c "
    sudo -u dsmrreader bash -c '
    sed -i \"s|DSMRREADER_DATALOGGER_MODE=.*|DSMRREADER_DATALOGGER_MODE=serial|\" compose.env
    sed -i \"s|DSMRREADER_DATALOGGER_SERIAL_PORT=.*|DSMRREADER_DATALOGGER_SERIAL_PORT=$USBDEV|\" compose.env
    '
    "
else
    # ser2net
    pct exec $CTID -- bash -c "
    sudo -u dsmrreader bash -c '
    sed -i \"s|DSMRREADER_DATALOGGER_MODE=.*|DSMRREADER_DATALOGGER_MODE=tcp|\" compose.env
    sed -i \"s|DSMRREADER_DATALOGGER_TCP_HOST=.*|DSMRREADER_DATALOGGER_TCP_HOST=$SER2NET_HOST|\" compose.env
    sed -i \"s|DSMRREADER_DATALOGGER_TCP_PORT=.*|DSMRREADER_DATALOGGER_TCP_PORT=$SER2NET_PORT|\" compose.env
    '
    "
fi

# ------------------------------------------------------------
# START DSMR-READER
# ------------------------------------------------------------
pct exec $CTID -- bash -c "
sudo -u dsmrreader bash -c '
cd ~ &&
podman-compose up -d
'
"

echo "------------------------------------------------------------"
echo "DSMR-reader LXC created and installed."
echo "Container ID: $CTID"
echo "Connection method: $([[ \"$METHOD\" == \"1\" ]] && echo USB || echo ser2net)"
echo "------------------------------------------------------------"
echo "Access DSMR-reader at: http://<container-ip>:7777"
echo "------------------------------------------------------------"
