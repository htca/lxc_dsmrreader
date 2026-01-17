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
echo -e "${GREEN}=== DSMR-reader v6 Proxmox LXC Helper (PVE 8 & 9) ===${NC}"
echo

# ---------------------- DETECT LXC CONFIG FLAG ----------------------
detect_lxc_flag() {
    if pct set 100 --help 2>/dev/null | grep -qE "^ *--lxc "; then
        echo "--lxc"
    elif pct set 100 --help 2>/dev/null | grep -qE "^ *-lxc "; then
        echo "-lxc"
    elif pct set 100 --help 2>/dev/null | grep -qE "^ *-raw "; then
        echo "-raw"
    else
        error "No supported LXC config flag found (unexpected Proxmox version)"
        exit 1
    fi
}

LXCFLAG=$(detect_lxc_flag)
info "Using LXC config flag: ${YELLOW}$LXCFLAG${NC}"
echo

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

TEMPLATE="
