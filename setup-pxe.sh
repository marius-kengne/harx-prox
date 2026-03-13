#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# harx-prox — PXE + Proxmox VE automated deployment
# Tested on: Ubuntu 22.04 LTS
# ============================================================

PXE_TFTP_DIR="/srv/tftp"
PXE_HTTP_DIR="/srv/http"
PROXMOX_DIR="$PXE_HTTP_DIR/proxmox"
PROXMOX_MOUNT="/mnt/proxmox-iso"
PROXMOX_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.1-1.iso"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

ISO_FILE_NAME="$(basename "$PROXMOX_ISO_URL")"
ISO_FILE_PATH="$PROXMOX_DIR/$ISO_FILE_NAME"

# ── Colours ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "\n${GREEN}[+]${NC} $*\n"; }
warn() { echo -e "\n${YELLOW}[!]${NC} $*\n"; }
die()  { echo -e "\n${RED}[✗]${NC} $*\n" >&2; exit 1; }

# ── Guards ───────────────────────────────────────────────────
require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run with sudo."
}

require_templates() {
    for f in pxe-menu.cfg answer.toml; do
        [[ -f "$TEMPLATE_DIR/$f" ]] || die "Missing template: $TEMPLATE_DIR/$f"
    done
}

# ── Network detection ────────────────────────────────────────
detect_interface() {
    ip route show default | awk '/default/ {print $5; exit}'
}

detect_ip() {
    local iface="$1"
    ip -4 addr show "$iface" | awk '/inet / {gsub(/\/.*/, "", $2); print $2; exit}'
}

# ── Syslinux file finder (Ubuntu 22.04 path-agnostic) ────────
find_syslinux_file() {
    # Searches common locations; prints the first match or exits with an error.
    local filename="$1"
    local candidates=(
        "/usr/lib/PXELINUX/$filename"
        "/usr/lib/syslinux/modules/bios/$filename"
        "/usr/share/syslinux/$filename"
        "/usr/lib/syslinux/$filename"
    )
    for path in "${candidates[@]}"; do
        [[ -f "$path" ]] && { echo "$path"; return 0; }
    done
    die "Cannot find '$filename' — ensure pxelinux and syslinux-common are installed."
}

# ── Copy all required PXE boot files ─────────────────────────
copy_pxe_files() {
    log "Copying PXE boot files"

    local files=(
        pxelinux.0
        ldlinux.c32
        menu.c32
        libutil.c32
        libcom32.c32
        vesamenu.c32
    )

    for f in "${files[@]}"; do
        local src
        src="$(find_syslinux_file "$f")"
        cp -v "$src" "$PXE_TFTP_DIR/"
    done
}

# ── Mount ISO (idempotent) ───────────────────────────────────
mount_iso() {
    log "Mounting Proxmox ISO"

    mkdir -p "$PROXMOX_MOUNT"

    if mountpoint -q "$PROXMOX_MOUNT"; then
        warn "$PROXMOX_MOUNT already mounted — unmounting first."
        umount "$PROXMOX_MOUNT"
    fi

    mount -o loop,ro "$ISO_FILE_PATH" "$PROXMOX_MOUNT" \
        || die "Failed to mount ISO."
}

# ── Verify boot files exist inside the ISO ───────────────────
verify_proxmox_boot() {
    local kernel="$PROXMOX_MOUNT/boot/linux26"
    local initrd="$PROXMOX_MOUNT/boot/initrd.img"

    [[ -f "$kernel" ]] || die "Kernel not found in ISO at $kernel"
    [[ -f "$initrd" ]] || die "initrd not found in ISO at $initrd"

    log "Proxmox boot files verified ✓"
}

# ── Main ─────────────────────────────────────────────────────
main() {
    require_root
    require_templates

    # ── 1. Network ───────────────────────────────────────────
    log "Detecting network"
    NET_IFACE="$(detect_interface)"
    [[ -n "$NET_IFACE" ]] || die "Could not detect default network interface."

    VM_IP="$(detect_ip "$NET_IFACE")"
    [[ -n "$VM_IP" ]]    || die "Could not detect IP on interface $NET_IFACE."

    echo "  Interface : $NET_IFACE"
    echo "  Server IP : $VM_IP"

    # ── 2. System update & packages ──────────────────────────
    log "Updating system"
    apt-get update -qq
    apt-get upgrade -y -qq

    log "Installing required packages"
    apt-get install -y -qq \
        dnsmasq \
        pxelinux \
        syslinux-common \
        nginx \
        wget \
        curl \
        rsync

    # Stop dnsmasq during setup to avoid port conflicts
    systemctl stop dnsmasq 2>/dev/null || true

    # ── 3. Directory structure ───────────────────────────────
    log "Creating directory structure"
    mkdir -p "$PXE_TFTP_DIR/pxelinux.cfg"
    mkdir -p "$PXE_HTTP_DIR/configs"
    mkdir -p "$PROXMOX_DIR"

    # ── 4. dnsmasq (ProxyDHCP) ───────────────────────────────
    log "Configuring dnsmasq (ProxyDHCP mode)"

    # Disable systemd-resolved stub listener if present (conflicts on port 53)
    if systemctl is-active --quiet systemd-resolved; then
        warn "systemd-resolved is running — disabling stub listener."
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/no-stub.conf <<RESOLVED
[Resolve]
DNSStubListener=no
RESOLVED
        systemctl restart systemd-resolved
    fi

    cat > /etc/dnsmasq.d/pxe.conf <<DNSMASQ
# ProxyDHCP: answers PXE option requests only; router still handles IPs.
port=0
interface=$NET_IFACE
bind-interfaces
log-dhcp

enable-tftp
tftp-root=$PXE_TFTP_DIR

dhcp-range=$VM_IP,proxy
dhcp-match=set:pxe,60,PXEClient
dhcp-boot=tag:pxe,pxelinux.0,$VM_IP
DNSMASQ

    systemctl enable dnsmasq
    systemctl restart dnsmasq \
        || die "dnsmasq failed to start — check 'journalctl -xe'."

    # ── 5. PXE boot files ────────────────────────────────────
    copy_pxe_files

    # ── 6. nginx ─────────────────────────────────────────────
    log "Configuring nginx"

    cat > /etc/nginx/sites-available/pxe <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root $PXE_HTTP_DIR;
    index index.html;

    server_name _;

    location /proxmox/ {
        autoindex on;
        sendfile  on;
    }

    location / {
        autoindex on;
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/pxe /etc/nginx/sites-enabled/pxe
    rm -f /etc/nginx/sites-enabled/default

    echo "<h1>PXE server — $VM_IP</h1>" > "$PXE_HTTP_DIR/index.html"

    nginx -t || die "nginx configuration test failed."
    systemctl enable nginx
    systemctl restart nginx

    # ── 7. Proxmox ISO ───────────────────────────────────────
    log "Ensuring Proxmox ISO is present"
    if [[ ! -f "$ISO_FILE_PATH" ]]; then
        log "Downloading Proxmox ISO (~1 GB) — please wait…"
        wget --progress=bar:force -O "$ISO_FILE_PATH" "$PROXMOX_ISO_URL" \
            || { rm -f "$ISO_FILE_PATH"; die "ISO download failed."; }
    else
        warn "ISO already present — skipping download."
    fi

    # ── 8. Mount and copy ISO contents ───────────────────────
    mount_iso
    verify_proxmox_boot

    log "Copying Proxmox files from ISO to HTTP root"
    rsync -a --info=progress2 "$PROXMOX_MOUNT/" "$PROXMOX_DIR/"

    umount "$PROXMOX_MOUNT"
    log "ISO unmounted ✓"

    # ── 9. PXE boot menu ─────────────────────────────────────
    log "Generating pxelinux.cfg/default from template"
    sed "s|__SERVER_IP__|$VM_IP|g" \
        "$TEMPLATE_DIR/pxe-menu.cfg" \
        > "$PXE_TFTP_DIR/pxelinux.cfg/default"

    # ── 10. Answer file ──────────────────────────────────────
    log "Installing answer.toml"
    cp "$TEMPLATE_DIR/answer.toml" "$PXE_HTTP_DIR/configs/answer.toml"

    # ── 11. Smoke tests ──────────────────────────────────────
    log "Running smoke tests"

    echo ""
    echo "── TFTP directory ──────────────────────────────────"
    ls -lh "$PXE_TFTP_DIR"

    echo ""
    echo "── Proxmox kernel (HTTP) ───────────────────────────"
    curl -sf --max-time 10 -o /dev/null \
         "http://localhost/proxmox/boot/linux26" \
        && echo "  linux26 ✓" \
        || die "linux26 not reachable over HTTP!"

    echo ""
    echo "── answer.toml (HTTP) ──────────────────────────────"
    curl -sf "http://localhost/configs/answer.toml" \
        && echo "" \
        || die "answer.toml not reachable over HTTP!"

    echo ""
    echo "── dnsmasq status ──────────────────────────────────"
    systemctl is-active dnsmasq \
        && echo "  dnsmasq active ✓" \
        || warn "dnsmasq is NOT running!"

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Setup complete."
    echo "  PXE server  : $VM_IP  (interface: $NET_IFACE)"
    echo "  TFTP root   : $PXE_TFTP_DIR"
    echo "  HTTP root   : $PXE_HTTP_DIR"
    echo "  Boot menu   : $PXE_TFTP_DIR/pxelinux.cfg/default"
    echo "  Answer file : http://$VM_IP/configs/answer.toml"
    echo "════════════════════════════════════════════════════"
    echo ""
    echo "  → Power on the mini-PC and select PXE boot."
    echo ""
}

main "$@"
