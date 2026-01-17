#!/usr/bin/env bash
set -Eeuo pipefail

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

on_error() {
    local exit_code=$?
    local line=$1
    local cmd=$2
    error "Command failed (exit ${exit_code}) at line ${line}: ${cmd}"
}

trap 'on_error $LINENO "$BASH_COMMAND"' ERR

if [[ "${DEBUG:-}" == "1" ]]; then
    set -x
fi

clear || true
echo -e "${GREEN}=== DSMR-reader v6 Proxmox LXC Helper (PVE 8 & 9) ===${NC}"
echo

if [[ "${EUID}" -ne 0 ]]; then
    error "Run this script as root (use sudo)."
    exit 1
fi

require_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Missing required command: $cmd"
        exit 1
    fi
}

require_command pct
require_command pvesh
require_command pveam

# ---------------------- DEFAULTS ----------------------
ENABLE_NESTING=${ENABLE_NESTING:-0}

# ---------------------- LXC CONFIG HELPERS ----------------------
apply_lxc_config() {
    local ctid=$1
    local profile_line="lxc.apparmor.profile: unconfined"
    local cap_line="lxc.cap.drop:"
    local config_path="/etc/pve/lxc/${ctid}.conf"

    if pct set "$ctid" --lxc "$profile_line" >/dev/null 2>&1 && pct set "$ctid" --lxc "$cap_line" >/dev/null 2>&1; then
        ok "Applied LXC config via --lxc."
        return
    fi

    if pct set "$ctid" -lxc "$profile_line" >/dev/null 2>&1 && pct set "$ctid" -lxc "$cap_line" >/dev/null 2>&1; then
        ok "Applied LXC config via -lxc."
        return
    fi

    if pct set "$ctid" -raw "$profile_line" >/dev/null 2>&1 && pct set "$ctid" -raw "$cap_line" >/dev/null 2>&1; then
        ok "Applied LXC config via -raw."
        return
    fi

    if [[ -w "$config_path" ]]; then
        sed -i '/^lxc\.apparmor\.profile:/d' "$config_path"
        sed -i '/^lxc\.cap\.drop:/d' "$config_path"
        printf '%s\n' "$profile_line" "$cap_line" >> "$config_path"
        ok "Applied LXC config via config file."
        return
    fi

    error "Unable to apply LXC config lines."
    exit 1
}

apply_usb_passthrough() {
    local ctid=$1
    local dev_path=$2
    local device_path_arg="path=${dev_path}"
    local config_path="/etc/pve/lxc/${ctid}.conf"
    local container_path="dev/$(basename "$dev_path")"
    local -a flags=(--device -device --dev -dev)
    local -a values=("$device_path_arg" "$dev_path")

    if [[ -w "$config_path" ]]; then
        local major_hex
        local minor_hex
        local major
        local minor
        local escaped_dev

        major_hex=$(stat -c '%t' "$dev_path")
        minor_hex=$(stat -c '%T' "$dev_path")
        major=$((16#$major_hex))
        minor=$((16#$minor_hex))
        escaped_dev=${dev_path//\//\\/}

        sed -i '/^dev0:/d' "$config_path"
        sed -i "\\|^lxc\\.mount\\.entry: ${escaped_dev} |d" "$config_path"
        sed -i "/^lxc\\.cgroup2\\.devices\\.allow: c ${major}:${minor} /d" "$config_path"
        printf 'lxc.mount.entry: %s %s none bind,optional,create=file\n' "$dev_path" "$container_path" >> "$config_path"
        printf 'lxc.cgroup2.devices.allow: c %s:%s rwm\n' "$major" "$minor" >> "$config_path"
        ok "Added USB passthrough via config file."
        return
    fi

    for flag in "${flags[@]}"; do
        for value in "${values[@]}"; do
            if pct set "$ctid" "${flag}0" "$value" >/dev/null 2>&1; then
                ok "Added USB passthrough via ${flag}0."
                return
            fi
        done
    done

    error "Unable to configure USB device passthrough."
    exit 1
}

set_compose_env_var() {
    local ctid=$1
    local key=$2
    local value=$3

    pct exec "$ctid" -- env KEY="$key" VALUE="$value" runuser -l dsmrreader -c '
        sed -i "/^${KEY}=.*/d" ~/compose.env
        printf "%s=%s\n" "$KEY" "$VALUE" >> ~/compose.env
    '
}

enable_compose_usb_device() {
    local ctid=$1
    local dev_path=$2

    pct exec "$ctid" -- env USBDEV="$dev_path" runuser -l dsmrreader -c 'sed -i -E \
        -e "s|^([[:space:]]*)#\\s*devices:|\\1devices:|" \
        -e "s|^([[:space:]]*)#\\s*-\\s*/dev/[^ ]+:/dev/[^ ]+|\\1- $USBDEV:$USBDEV|" \
        -e "s|/dev/ttyUSB0:/dev/ttyUSB0|$USBDEV:$USBDEV|" \
        ~/compose.yml'
}

disable_compose_usb_device() {
    local ctid=$1

    pct exec "$ctid" -- runuser -l dsmrreader -c 'sed -i -E \
        "/^[[:space:]]*devices:/,/^[[:space:]]*volumes:/ { /^[[:space:]]*volumes:/! s/^/# / }" \
        ~/compose.yml'
}

generate_django_secret() {
    local secret=""
    local attempts=0

    while [[ ${#secret} -lt 50 && $attempts -lt 5 ]]; do
        secret=$(
            (
                set +o pipefail
                LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 50
            )
        )
        attempts=$((attempts + 1))
    done

    if [[ ${#secret} -lt 50 ]] && command -v openssl >/dev/null 2>&1; then
        secret=$(
            (
                set +o pipefail
                openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 50
            )
        )
    fi

    if [[ ${#secret} -lt 50 ]]; then
        error "Unable to generate DJANGO_SECRET_KEY automatically."
        exit 1
    fi

    printf '%s' "$secret"
}

remove_feature_nesting() {
    local ctid=$1
    local config_path="/etc/pve/lxc/${ctid}.conf"

    if [[ ! -w "$config_path" ]]; then
        warn "Cannot edit ${config_path}; skipping nesting adjustment."
        return
    fi

    local features
    features=$(sed -n 's/^features:[[:space:]]*//p' "$config_path" | head -n 1)

    if [[ -z "$features" ]]; then
        return
    fi

    local updated
    updated=$(printf '%s' "$features" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^nesting=' | paste -sd, -)

    if [[ -z "$updated" ]]; then
        sed -i '/^features:/d' "$config_path"
    else
        sed -i "s/^features:.*/features: $updated/" "$config_path"
    fi
}

start_container() {
    local ctid=$1
    local output=""
    local status=0

    if output=$(pct start "$ctid" 2>&1); then
        return 0
    fi
    status=$?

    if echo "$output" | grep -q "lxc.apparmor.profile overrides"; then
        warn "AppArmor override conflicts with nesting; retrying without nesting."
        if [[ "${KEEP_NESTING:-}" == "1" ]]; then
            error "KEEP_NESTING=1 set; not modifying nesting."
            echo "$output"
            exit 1
        fi
        remove_feature_nesting "$ctid"
        if output=$(pct start "$ctid" 2>&1); then
            warn "Container started without nesting; systemd isolation may be limited."
            return 0
        fi
        status=$?
    fi

    error "Failed to start container."
    echo "$output"
    if [[ -f "/var/log/pve/lxc/${ctid}.log" ]]; then
        warn "Last 200 lines of /var/log/pve/lxc/${ctid}.log:"
        tail -n 200 "/var/log/pve/lxc/${ctid}.log"
    elif command -v journalctl >/dev/null 2>&1; then
        warn "Last 200 lines of journalctl for pve-container@${ctid}:"
        journalctl -u "pve-container@${ctid}" --no-pager -n 200 || true
    fi
    if [[ "${ENABLE_PCT_DEBUG:-1}" == "1" ]]; then
        warn "Attempting pct start --debug to capture /tmp/lxc-${ctid}.log ..."
        pct start "$ctid" --debug >/dev/null 2>&1 || true
        if [[ -f "/tmp/lxc-${ctid}.log" ]]; then
            warn "Last 200 lines of /tmp/lxc-${ctid}.log:"
            tail -n 200 "/tmp/lxc-${ctid}.log"
        fi
    fi
    exit 1
}

# ---------------------- AUTO CTID ----------------------
CTID=$(pvesh get /cluster/nextid)
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
    pveam download local "$LATEST_TEMPLATE"
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
    USBDEV_REAL=$(readlink -f "$USBDEV" || true)

    if [[ -z "$USBDEV_REAL" || ! -c "$USBDEV_REAL" ]]; then
        error "Unable to resolve USB device path for passthrough."
        exit 1
    fi

    ok "Selected USB device: ${YELLOW}$USBDEV${NC}"
    if [[ "$USBDEV_REAL" != "$USBDEV" ]]; then
        info "Resolved device path: ${YELLOW}$USBDEV_REAL${NC}"
        USBDEV="$USBDEV_REAL"
    fi
    echo

elif [[ "$METHOD" == "2" ]]; then
    read -rp "$(echo -e "${CYAN}Enter ser2net host: ${NC}")" SER2NET_HOST
    read -rp "$(echo -e "${CYAN}Enter ser2net port: ${NC}")" SER2NET_PORT
    echo
else
    error "Invalid choice"
    exit 1
fi

# ---------------------- DSMR-READER INPUTS ----------------------
info "Collecting DSMR-reader configuration..."

read -rp "$(echo -e "${CYAN}Admin username: ${NC}")" DSMR_ADMIN_USER
while [[ -z "$DSMR_ADMIN_USER" ]]; do
    warn "Admin username cannot be empty."
    read -rp "$(echo -e "${CYAN}Admin username: ${NC}")" DSMR_ADMIN_USER
done

read -rsp "$(echo -e "${CYAN}Admin password: ${NC}")" DSMR_ADMIN_PASSWORD
echo
while [[ -z "$DSMR_ADMIN_PASSWORD" ]]; do
    warn "Admin password cannot be empty."
    read -rsp "$(echo -e "${CYAN}Admin password: ${NC}")" DSMR_ADMIN_PASSWORD
    echo
done

read -rp "$(echo -e "${CYAN}DJANGO_SECRET_KEY (leave empty to generate): ${NC}")" DJANGO_SECRET_KEY
if [[ -z "$DJANGO_SECRET_KEY" ]]; then
    DJANGO_SECRET_KEY=$(generate_django_secret)
fi

echo

# ---------------------- CREATE LXC ----------------------
info "Creating LXC ${YELLOW}$CTID${NC}..."

FEATURES="fuse=1,keyctl=1"
if [[ "$ENABLE_NESTING" == "1" ]]; then
    FEATURES="nesting=1,${FEATURES}"
fi

pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores 2 \
    --memory "$MEMORY" \
    --swap 512 \
    --rootfs "local-lvm:$DISK" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
    --features "$FEATURES" \
    --unprivileged 1

pct set "$CTID" -onboot 1
pct set "$CTID" -mp0 "/dev/fuse,mp=/dev/fuse"

# Apply required LXC config lines
apply_lxc_config "$CTID"

# USB passthrough
if [[ "$METHOD" == "1" ]]; then
    apply_usb_passthrough "$CTID" "$USBDEV"
fi

start_container "$CTID"
sleep 5
ok "LXC ${YELLOW}$CTID${NC} created and started."
echo

# ---------------------- INSTALL DSMR-READER ----------------------
info "Installing DSMR-reader inside container..."

pct exec "$CTID" -- bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update &&
apt-get install -y podman podman-compose podman-docker uidmap git systemd wget ca-certificates fuse-overlayfs crun &&
if ! id -u dsmrreader >/dev/null 2>&1; then
  useradd dsmrreader --create-home
fi &&
usermod -a -G dialout dsmrreader &&
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger dsmrreader || true
else
  echo 'loginctl not available; skipping linger enable.'
fi
"

ok "Base packages and user created."
echo

# ---------------------- DOWNLOAD COMPOSE FILES ----------------------
info "Downloading DSMR-reader compose files..."

pct exec "$CTID" -- bash -c "
runuser -l dsmrreader -c '
cd ~ &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.yml -O compose.yml &&
wget -q https://raw.githubusercontent.com/dsmrreader/dsmr-reader/refs/heads/v6/provisioning/container/compose.prod.env -O compose.env
'
"

ok "Compose files downloaded."
echo

# ---------------------- CONFIGURE compose.env ----------------------
info "Configuring DSMR-reader environment..."

DUID=$(pct exec "$CTID" -- id -u dsmrreader)
DGID=$(pct exec "$CTID" -- id -g dsmrreader)

set_compose_env_var "$CTID" DUID "$DUID"
set_compose_env_var "$CTID" DGID "$DGID"
set_compose_env_var "$CTID" DJANGO_SECRET_KEY "$DJANGO_SECRET_KEY"
set_compose_env_var "$CTID" DSMRREADER_ADMIN_USER "$DSMR_ADMIN_USER"
set_compose_env_var "$CTID" DSMRREADER_ADMIN_PASSWORD "$DSMR_ADMIN_PASSWORD"

if [[ "$METHOD" == "1" ]]; then
    set_compose_env_var "$CTID" DSMRREADER_DATALOGGER_MODE "serial"
    set_compose_env_var "$CTID" DSMRREADER_DATALOGGER_SERIAL_PORT "$USBDEV"
    enable_compose_usb_device "$CTID" "$USBDEV"
else
    set_compose_env_var "$CTID" DSMRREADER_DATALOGGER_MODE "tcp"
    set_compose_env_var "$CTID" DSMRREADER_DATALOGGER_TCP_HOST "$SER2NET_HOST"
    set_compose_env_var "$CTID" DSMRREADER_DATALOGGER_TCP_PORT "$SER2NET_PORT"
    disable_compose_usb_device "$CTID"
fi

ok "compose.env and compose.yml configured."
echo

# ---------------------- START DSMR-READER ----------------------
info "Starting DSMR-reader containers..."

pct exec "$CTID" -- bash -c "
runuser -l dsmrreader -c '
cd ~ &&
podman-compose up -d &&
if podman-compose systemd -a register; then
  systemctl --user daemon-reload || true
  systemctl --user enable podman-compose@dsmrreader || true
  systemctl --user start podman-compose@dsmrreader || true
else
  echo "podman-compose systemd registration failed; continuing without autostart."
fi
'
"

ok "DSMR-reader containers started."
echo

echo -e "${GREEN}------------------------------------------------------------${NC}"
echo -e "${GREEN}DSMR-reader LXC created and installed.${NC}"
echo -e "  ${CYAN}Container ID:${NC} ${YELLOW}$CTID${NC}"
echo -e "  ${CYAN}Connection method:${NC} ${YELLOW}$([[ \"$METHOD\" == \"1\" ]] && echo USB || echo ser2net)${NC}"
echo -e "${GREEN}------------------------------------------------------------${NC}"
echo -e "Access DSMR-reader at: ${YELLOW}http://<container-ip>:7777${NC}"
echo -e "${GREEN}------------------------------------------------------------${NC}"
