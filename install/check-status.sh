#!/usr/bin/env bash
# Check ZeroTier and proxy install status on the Pi.
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
NODE_INFO="${INSTALL_DIR}/node-info.env"
SERVICE_NAME="${PROXYPI_SERVICE_NAME:-improved_proxy.service}"

echo "=== ZeroTier ==="
if command -v zerotier-cli >/dev/null 2>&1; then
  sudo zerotier-cli info
  sudo zerotier-cli listnetworks
else
  echo "ZeroTier not installed"
fi

echo ""
echo "=== Node info ==="
if [[ -f "${NODE_INFO}" ]]; then
  cat "${NODE_INFO}"
else
  echo "Not found: ${NODE_INFO} (run join.sh first)"
fi

echo ""
echo "=== Proxy service ==="
if systemctl list-unit-files "${SERVICE_NAME}" >/dev/null 2>&1; then
  systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true
  systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true
else
  echo "Service not installed"
fi

echo ""
echo "=== Listening ports ==="
if command -v ss >/dev/null 2>&1; then
  ss -tlnp 2>/dev/null | grep python || echo "No python listeners"
fi