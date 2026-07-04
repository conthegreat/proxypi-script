#!/usr/bin/env bash
# Bootstrap entry point — run with:
#   curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/join.sh | bash
set -euo pipefail

REPO_RAW="${PROXYPI_REPO_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"
INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
TMP_SETUP="$(mktemp)"

cleanup() {
  rm -f "$TMP_SETUP"
}
trap cleanup EXIT

mkdir -p "$INSTALL_DIR"
echo "[*] Downloading setup script from ${REPO_RAW}"
curl -fsSL "${REPO_RAW}/install/setup.sh" -o "$TMP_SETUP"
chmod +x "$TMP_SETUP"
exec "$TMP_SETUP" "$@"