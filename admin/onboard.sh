#!/usr/bin/env bash
# Interactive operator wizard: register a new Pi after ZeroTier approval.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_RAW="${PROXYPI_REPO_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"

echo "=== ProxyPi onboard wizard ==="
echo ""

read -r -p "Hostname (e.g. pi-3): " HOSTNAME
[[ -n "${HOSTNAME}" ]] || { echo "Hostname required." >&2; exit 1; }

read -r -p "ZeroTier Node ID (10-char, from join.sh output): " ZT_NODE_ID
read -r -p "ZeroTier IP (optional, e.g. 10.147.17.200): " ZT_IP

if [[ -z "${RADIUS_SECRET:-}" ]]; then
  read -r -s -p "RADIUS secret: " RADIUS_SECRET
  echo ""
  export RADIUS_SECRET
fi

"${SCRIPT_DIR}/assign-ports.sh" "${HOSTNAME}" "${ZT_NODE_ID}" "${ZT_IP}"

echo ""
echo "Approve device ${ZT_NODE_ID} in ZeroTier Central if not already done:"
echo "  https://my.zerotier.com/network/664bb06760e47198"
echo ""
echo "User can check status on their Pi with:"
echo "  curl -fsSL ${REPO_RAW}/install/check-status.sh | bash"