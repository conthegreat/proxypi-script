#!/usr/bin/env bash
# Activates the proxy after ZeroTier approval and port assignment.
# Run on the Pi (operator sends this command after assigning ports):
#
#   curl -fsSL .../install/activate.sh | SOCKS_PORT=18100 HTTP_PORT=58100 RADIUS_SECRET='secret' bash
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
SERVICE_NAME="${PROXYPI_SERVICE_NAME:-improved_proxy.service}"
PROXY_ENV="${INSTALL_DIR}/proxy.env"
NODE_INFO="${INSTALL_DIR}/node-info.env"
CONFIG_FILE="${INSTALL_DIR}/config.defaults"

die() { echo "[-] $*" >&2; exit 1; }

[[ -f "${INSTALL_DIR}/proxyscript.py" ]] \
  || die "Proxy not installed. Run join.sh first."

SOCKS_PORT="${SOCKS_PORT:-}"
HTTP_PORT="${HTTP_PORT:-}"
RADIUS_SECRET="${RADIUS_SECRET:-}"
RADIUS_SERVER="${RADIUS_SERVER:-10.147.17.33}"
PROXY_LOG_DIR="${PROXY_LOG_DIR:-/var/log/proxy}"

[[ -n "${SOCKS_PORT}" ]] || die "SOCKS_PORT is required"
[[ -n "${HTTP_PORT}" ]] || die "HTTP_PORT is required"
[[ -n "${RADIUS_SECRET}" ]] || die "RADIUS_SECRET is required"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln | awk '{print $4}' | grep -q ":${port}\$"
  else
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"
  fi
}

port_in_use "${SOCKS_PORT}" && die "SOCKS port ${SOCKS_PORT} is already in use on this host"
port_in_use "${HTTP_PORT}" && die "HTTP port ${HTTP_PORT} is already in use on this host"

cat >"${PROXY_ENV}" <<EOF
SOCKS_PORT=${SOCKS_PORT}
HTTP_PORT=${HTTP_PORT}
RADIUS_SERVER=${RADIUS_SERVER}
RADIUS_SECRET=${RADIUS_SECRET}
PROXY_LOG_DIR=${PROXY_LOG_DIR}
EOF
chmod 600 "${PROXY_ENV}"

if [[ -f "${NODE_INFO}" ]]; then
  sed -i 's/^STATUS=.*/STATUS=active/' "${NODE_INFO}" 2>/dev/null || true
  {
    echo "SOCKS_PORT=${SOCKS_PORT}"
    echo "HTTP_PORT=${HTTP_PORT}"
  } >> "${NODE_INFO}"
fi

echo "[*] Enabling and starting ${SERVICE_NAME}"
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"
sleep 2

if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo "[+] Proxy is running"
  echo "    SOCKS: 0.0.0.0:${SOCKS_PORT}"
  echo "    HTTP:  0.0.0.0:${HTTP_PORT}"
  sudo systemctl status "${SERVICE_NAME}" --no-pager -n 5
else
  die "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 50"
fi