#!/usr/bin/env bash
set -euo pipefail

# =========================
# PXE + Proxmox automation
# =========================

: "${PXE_TFTP_DIR:=/srv/tftp}"
: "${PXE_HTTP_DIR:=/srv/http}"
: "${PROXMOX_DIR:=${PXE_HTTP_DIR}/proxmox}"
: "${PROXMOX_MOUNT:=/mnt/proxmox}"
: "${PROXMOX_ISO_URL:=http://download.proxmox.com/iso/proxmox-ve_8.3-1.iso}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

ISO_FILE_NAME="$(basename "${PROXMOX_ISO_URL}")"
ISO_FILE_PATH="${PROXMOX_DIR}/${ISO_FILE_NAME}"

log() { echo -e "\n[+] $*\n"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run with sudo"
    exit 1
  fi
}

detect_interface() {
  ip route | grep default | awk '{print $5}' | head -n1
}

detect_ip() {
  hostname -I | awk '{print $1}'
}

main(){

require_root

log "Detecting network"

NET_IFACE=$(detect_interface)
VM_IP=$(detect_ip)

echo "Interface: $NET_IFACE"
echo "Server IP: $VM_IP"

log "Updating system"

apt update
apt upgrade -y

log "Installing required packages"

apt install -y dnsmasq syslinux-common pxelinux nginx wget unzip

log "Creating directories"

mkdir -p "$PXE_TFTP_DIR"
mkdir -p "$PXE_TFTP_DIR/pxelinux.cfg"
mkdir -p "$PXE_HTTP_DIR"
mkdir -p "$PXE_HTTP_DIR/configs"
mkdir -p "$PROXMOX_DIR"

log "Configuring dnsmasq (ProxyDHCP)"

cat > /etc/dnsmasq.d/pxe.conf <<EOF
port=0
interface=$NET_IFACE
bind-interfaces

enable-tftp
tftp-root=$PXE_TFTP_DIR

dhcp-range=192.168.0.0,proxy,255.255.255.0
dhcp-match=set:pxe,60,PXEClient
dhcp-boot=tag:pxe,pxelinux.0
EOF

systemctl enable dnsmasq
systemctl restart dnsmasq

log "Copying PXE boot files"

for f in pxelinux.0 ldlinux.c32 menu.c32 libutil.c32 libcom32.c32 vesamenu.c32; do

src=$(find /usr/lib/syslinux /usr/share/syslinux -name "$f" 2>/dev/null | head -n1)

if [[ -n "$src" ]]; then
cp "$src" "$PXE_TFTP_DIR/"
fi

done

log "Configuring nginx"

sed -i "s|root /var/www/html;|root $PXE_HTTP_DIR;|" /etc/nginx/sites-available/default || true

echo "<h1>PXE server running</h1>" > "$PXE_HTTP_DIR/index.html"

systemctl enable nginx
systemctl restart nginx

log "Downloading Proxmox ISO"

if [[ ! -f "$ISO_FILE_PATH" ]]; then
wget -O "$ISO_FILE_PATH" "$PROXMOX_ISO_URL"
fi

log "Mounting ISO"

mkdir -p "$PROXMOX_MOUNT"

mount -o loop "$ISO_FILE_PATH" "$PROXMOX_MOUNT"

log "Installing PXE menu"

sed "s/__SERVER_IP__/$VM_IP/g" \
"$TEMPLATE_DIR/pxe-menu.cfg" \
> "$PXE_TFTP_DIR/pxelinux.cfg/default"

log "Installing automated install config"

cp "$TEMPLATE_DIR/answer.toml" \
"$PXE_HTTP_DIR/configs/answer.toml"

log "Running checks"

echo
echo "PXE files:"
ls "$PXE_TFTP_DIR"

echo
echo "HTTP test:"
curl http://localhost || true

echo
echo "Setup complete."
echo
echo "Boot your mini-PC using PXE now."

}

main
