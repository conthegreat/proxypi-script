#!/usr/bin/env bash
# Update proxyscript.py to the secure (RFC1918/ZT destination filter) build.
# Does NOT touch proxy.env — SOCKS/HTTP ports and RADIUS secret stay identical.
#
# Usage (on a Pi, as the proxy user, e.g. con-root):
#   curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/admin/update-secure-script.sh | bash
# Or copy this file and: bash update-secure-script.sh
#
# Rollback:
#   bash update-secure-script.sh --rollback
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
SERVICE_NAME="${PROXYPI_SERVICE_NAME:-improved_proxy.service}"
SCRIPT_URL="${PROXYSCRIPT_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main/proxyscript.py}"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="${INSTALL_DIR}/backups"
MARKER="${BACKUP_DIR}/LAST_SECURE_UPDATE"

die() { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }

[[ -d "${INSTALL_DIR}" ]] || die "Install dir not found: ${INSTALL_DIR}"
[[ -f "${INSTALL_DIR}/proxyscript.py" ]] || die "proxyscript.py missing in ${INSTALL_DIR}"

show_ports() {
  if [[ -f "${INSTALL_DIR}/proxy.env" ]]; then
    echo "    proxy.env ports (unchanged by this tool):"
    grep -E '^(SOCKS_PORT|HTTP_PORT|RADIUS_SERVER)=' "${INSTALL_DIR}/proxy.env" | sed 's/^/      /' || true
  else
    echo "    WARNING: proxy.env missing"
  fi
}

do_update() {
  mkdir -p "${BACKUP_DIR}"
  local bak="${BACKUP_DIR}/proxyscript.py.pre-secure.${STAMP}"
  info "Backing up current script → ${bak}"
  cp -a "${INSTALL_DIR}/proxyscript.py" "${bak}"
  echo "${bak}" > "${MARKER}"

  show_ports

  info "Downloading secure proxyscript.py"
  curl -fsSL "${SCRIPT_URL}" -o "${INSTALL_DIR}/proxyscript.py.new"
  # sanity: must contain destination filter
  grep -q "_DEFAULT_BLOCKED_NETWORKS" "${INSTALL_DIR}/proxyscript.py.new" \
    || die "Downloaded file missing destination filter — aborting"

  if [[ -x "${INSTALL_DIR}/venv/bin/python3" ]]; then
    "${INSTALL_DIR}/venv/bin/python3" -m py_compile "${INSTALL_DIR}/proxyscript.py.new" \
      || die "py_compile failed — aborting (ports untouched, service not restarted)"
  fi

  mv "${INSTALL_DIR}/proxyscript.py.new" "${INSTALL_DIR}/proxyscript.py"
  ok "Installed secure script"

  info "Restarting ${SERVICE_NAME} (proxy.env not modified)"
  sudo systemctl restart "${SERVICE_NAME}"
  sleep 2
  systemctl is-active "${SERVICE_NAME}" >/dev/null \
    || die "Service failed to start — run: $0 --rollback"

  ok "Service active"
  journalctl -u "${SERVICE_NAME}" -n 12 --no-pager | grep -E "Destination filter|SOCKS proxy|HTTP proxy|ERROR" || true
  show_ports
  ok "Done. Rollback: bash $0 --rollback  (or restore ${bak})"
}

do_rollback() {
  local bak=""
  if [[ -f "${MARKER}" ]]; then
    bak="$(cat "${MARKER}")"
  fi
  if [[ -z "${bak}" || ! -f "${bak}" ]]; then
    # pick newest pre-secure backup
    bak="$(ls -1t "${BACKUP_DIR}"/proxyscript.py.pre-secure.* 2>/dev/null | head -1 || true)"
  fi
  [[ -n "${bak}" && -f "${bak}" ]] || die "No backup found under ${BACKUP_DIR}"

  info "Restoring ${bak}"
  show_ports
  cp -a "${bak}" "${INSTALL_DIR}/proxyscript.py"
  sudo systemctl restart "${SERVICE_NAME}"
  sleep 2
  systemctl is-active "${SERVICE_NAME}" >/dev/null || die "Service failed after rollback"
  ok "Rolled back and service active"
  show_ports
}

case "${1:-}" in
  --rollback|-r) do_rollback ;;
  --help|-h)
    echo "Usage: $0 [--rollback]"
    echo "  default     install secure proxyscript.py, restart service"
    echo "  --rollback  restore previous proxyscript.py, restart service"
    echo "Ports always come from proxy.env and are never changed."
    ;;
  "") do_update ;;
  *) die "Unknown arg: $1 (try --help)" ;;
esac
