#!/usr/bin/env bash
set -euo pipefail

# =========================
# PXE VM - Steps 2 to 7
# =========================

# ---- Config ----
: "${PXE_TFTP_DIR:=/srv/tftp}"
: "${PXE_HTTP_DIR:=/srv/http}"
: "${PROXMOX_DIR:=${PXE_HTTP_DIR}/proxmox}"
: "${PROXMOX_MOUNT:=/mnt/proxmox}"
: "${PROXMOX_ISO_URL:=http://download.proxmox.com/iso/proxmox-ve_8.3-1.iso}"

ISO_FILE_NAME="$(basename "${PROXMOX_ISO_URL}")"
ISO_FILE_PATH="${PROXMOX_DIR}/${ISO_FILE_NAME}"

log() { echo -e "\n[+] $*\n"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (use: sudo $0)"
    exit 1
  fi
}

# ---- Nginx ----
configure_nginx_root() {
  local default_site="/etc/nginx/sites-available/default"

  if [[ ! -f "${default_site}" ]]; then
    echo "Nginx default site not found at ${default_site}"
    exit 1
  fi

  if grep -qE '^\s*root\s+' "${default_site}"; then
    sed -i "s|^\s*root\s\+.*;|    root ${PXE_HTTP_DIR};|g" "${default_site}"
  else
    sed -i "0,/server\s*{/s//server {\n    root ${PXE_HTTP_DIR};/" "${default_site}"
  fi

  mkdir -p "${PXE_HTTP_DIR}"
  echo "<html><body><h1>PXE HTTP OK</h1></body></html>" > "${PXE_HTTP_DIR}/index.html"

  if ! grep -q 'autoindex on' "${default_site}"; then
    sed -i "/root ${PXE_HTTP_DIR};/a\\    autoindex on;" "${default_site}"
  fi

  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx
}

# ---- ISO mount ----
mount_iso() {
  mkdir -p "${PROXMOX_MOUNT}"

  if mountpoint -q "${PROXMOX_MOUNT}"; then
    log "ISO already mounted on ${PROXMOX_MOUNT}"
    return 0
  fi

  mount -o loop,ro "${ISO_FILE_PATH}" "${PROXMOX_MOUNT}"
  log "Mounted ISO: ${ISO_FILE_PATH} -> ${PROXMOX_MOUNT}"

  if ! grep -qF "${ISO_FILE_PATH}" /etc/fstab; then
    echo "${ISO_FILE_PATH}  ${PROXMOX_MOUNT}  iso9660  loop,ro,nofail  0  0" >> /etc/fstab
    log "Added ISO mount to /etc/fstab"
  fi
}

# ---- Main ----
main() {
  require_root

  log "Step 2/7: Update system"
  apt update
  apt upgrade -y

  log "Step 3/7: Install required packages"
  apt install -y dnsmasq syslinux-common pxelinux nginx wget unzip

  log "Step 4/7: Create PXE directories"
  mkdir -p "${PXE_TFTP_DIR}" "${PROXMOX_DIR}"

  log "Step 4.1: Copy PXE boot files to TFTP root"
  for f in pxelinux.0 ldlinux.c32 menu.c32 libutil.c32; do
    src="$(find /usr/lib/syslinux /usr/share/syslinux -name "${f}" 2>/dev/null | head -n1)"
    if [[ -n "${src}" ]]; then
      cp -u "${src}" "${PXE_TFTP_DIR}/"
    else
      echo "WARNING: PXE file not found: ${f}"
    fi
  done
  mkdir -p "${PXE_TFTP_DIR}/pxelinux.cfg"

  log "Step 5/7: Configure Nginx"
  configure_nginx_root

  log "Step 6/7: Download Proxmox ISO"
  if [[ -f "${ISO_FILE_PATH}" ]]; then
    echo "ISO already exists: ${ISO_FILE_PATH}"
  else
    wget -O "${ISO_FILE_PATH}" "${PROXMOX_ISO_URL}"
  fi

  log "Step 7/7: Mount ISO"
  mount_iso

  log "Quick checks"
  echo "IPs:"
  ip -4 addr show | sed -n 's/^\s*inet\s\+\([0-9.\/]\+\).*/- \1/p'

  echo
  echo "HTTP test:"
  curl -fsS http://localhost >/dev/null && echo "- OK: http://localhost -> ${PXE_HTTP_DIR}" || echo "- ERROR: HTTP not responding"

  echo
  echo "ISO file:"
  ls -lh "${ISO_FILE_PATH}" || true

  echo
  echo "ISO mount:"
  ls -lah "${PROXMOX_MOUNT}" | head -n 20 || true

  log "Done. Next: configure dnsmasq (DHCP+TFTP) + PXE boot menu."
}

main "$@"
