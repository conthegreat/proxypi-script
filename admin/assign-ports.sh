#!/usr/bin/env bash
# Operator tool: assign unique SOCKS/HTTP ports and print activation command.
#
# Usage:
#   ./assign-ports.sh <hostname> [zt_node_id] [zt_ip]
#
# Example:
#   RADIUS_SECRET='your-secret' ./assign-ports.sh pi-3 a1b2c3d4e5 10.147.17.200
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/ports-registry.json"
REPO_RAW="${PROXYPI_REPO_URL:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"

usage() {
  echo "Usage: $0 <hostname> [zt_node_id] [zt_ip]" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage

HOSTNAME="$1"
ZT_NODE_ID="${2:-}"
ZT_IP="${3:-}"

python3 - "$REGISTRY" "$HOSTNAME" "$ZT_NODE_ID" "$ZT_IP" <<'PY'
import json
import sys
from pathlib import Path

registry_path = Path(sys.argv[1])
hostname = sys.argv[2]
zt_node_id = sys.argv[3]
zt_ip = sys.argv[4]

data = json.loads(registry_path.read_text())
nodes = data.setdefault("nodes", [])
ranges = data["ranges"]

used_socks = {n["socks_port"] for n in nodes}
used_http = {n["http_port"] for n in nodes}

for existing in nodes:
    if existing["hostname"] == hostname:
        print(json.dumps({"error": "hostname_exists", "node": existing}, indent=2))
        sys.exit(2)

socks_port = None
http_port = None
socks_start = max(ranges["socks"]["min"], 18100)
http_start = max(ranges["http"]["min"], 58100)
for candidate in range(socks_start, ranges["socks"]["max"] + 1):
    if candidate in used_socks:
        continue
    for http_candidate in range(http_start, ranges["http"]["max"] + 1):
        if http_candidate in used_http:
            continue
        socks_port = candidate
        http_port = http_candidate
        break
    if socks_port is not None:
        break

if socks_port is None:
    print(json.dumps({"error": "no_ports_available"}, indent=2))
    sys.exit(3)

node = {
    "hostname": hostname,
    "zt_ip": zt_ip,
    "zt_node_id": zt_node_id,
    "socks_port": socks_port,
    "http_port": http_port,
    "status": "assigned",
}
nodes.append(node)
registry_path.write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(node, indent=2))
PY

ASSIGN_RESULT=$?
[[ ${ASSIGN_RESULT} -eq 0 ]] || exit "${ASSIGN_RESULT}"

SOCKS_PORT="$(python3 -c "import json; print(json.load(open('${REGISTRY}'))['nodes'][-1]['socks_port'])")"
HTTP_PORT="$(python3 -c "import json; print(json.load(open('${REGISTRY}'))['nodes'][-1]['http_port'])")"

if [[ -z "${RADIUS_SECRET:-}" ]]; then
  echo ""
  echo "[!] Set RADIUS_SECRET in your environment to print the full activation command."
  echo "    Assigned ports: SOCKS=${SOCKS_PORT} HTTP=${HTTP_PORT}"
  echo "    Registry updated: ${REGISTRY}"
  exit 0
fi

cat <<EOF

================================================================================
 Node registered: ${HOSTNAME}
================================================================================
SOCKS port:  ${SOCKS_PORT}
HTTP port:   ${HTTP_PORT}

Send this to the Pi operator (after ZeroTier approval):

  curl -fsSL ${REPO_RAW}/install/activate.sh | \\
    SOCKS_PORT=${SOCKS_PORT} HTTP_PORT=${HTTP_PORT} RADIUS_SECRET='${RADIUS_SECRET}' bash

Registry updated: ${REGISTRY}
================================================================================
EOF