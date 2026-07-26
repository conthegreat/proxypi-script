#!/usr/bin/env bash
# ProxyPi — one-line installer for operators.
# Run on your Raspberry Pi (via SSH):
#   curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/join.sh | bash
#
# After it finishes, register at: https://proxypi.co.uk/join
set -euo pipefail

REPO_RAW="${PROXYPI_REPO_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"
INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
TMP_SETUP="$(mktemp)"

cleanup() {
  rm -f "$TMP_SETUP"
}
trap cleanup EXIT

mkdir -p "$INSTALL_DIR"
echo ""
echo "[*] ProxyPi installer — downloading setup from GitHub…"
echo "    (this may take a few minutes on first run)"
curl -fsSL "${REPO_RAW}/install/setup.sh" -o "$TMP_SETUP"
chmod +x "$TMP_SETUP"
exec "$TMP_SETUP" "$@"