#!/usr/bin/env bash
# ProxyPi — one-line leave / uninstall for operators.
#
#   curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/leave.sh | bash
#
# Non-interactive:
#   curl -fsSL .../leave.sh | CONFIRM=yes bash
#
# Full wipe (proxy files + leave ZT + uninstall ZT):
#   curl -fsSL .../leave.sh | CONFIRM=yes LEAVE_PURGE=1 LEAVE_REMOVE_ZT=1 bash
set -euo pipefail

REPO_RAW="${PROXYPI_REPO_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"
TMP_LEAVE="$(mktemp)"

cleanup() {
  rm -f "$TMP_LEAVE"
}
trap cleanup EXIT

echo ""
echo "[*] ProxyPi leave — downloading leave script from GitHub…"
curl -fsSL "${REPO_RAW}/install/leave.sh" -o "$TMP_LEAVE"
chmod +x "$TMP_LEAVE"
# Forward env (CONFIRM, LEAVE_*) to the real script
exec env \
  CONFIRM="${CONFIRM:-}" \
  LEAVE_PURGE="${LEAVE_PURGE:-0}" \
  LEAVE_WIPE_LOGS="${LEAVE_WIPE_LOGS:-0}" \
  LEAVE_REMOVE_ZT="${LEAVE_REMOVE_ZT:-0}" \
  LEAVE_KEEP_ZT="${LEAVE_KEEP_ZT:-0}" \
  LEAVE_NOTIFY_URL="${LEAVE_NOTIFY_URL:-}" \
  PROXYPI_INSTALL_DIR="${PROXYPI_INSTALL_DIR:-}" \
  PROXYPI_SERVICE_NAME="${PROXYPI_SERVICE_NAME:-}" \
  bash "$TMP_LEAVE" "$@"
