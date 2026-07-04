#!/usr/bin/env bash
# List all registered proxy nodes and port assignments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${SCRIPT_DIR}/ports-registry.json"

python3 - "$REGISTRY" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
nodes = data.get("nodes", [])
if not nodes:
    print("No nodes registered.")
    raise SystemExit(0)

print(f"{'HOSTNAME':<16} {'ZT IP':<16} {'SOCKS':<8} {'HTTP':<8} {'STATUS':<10} NODE ID")
print("-" * 72)
for node in nodes:
    print(
        f"{node.get('hostname',''):<16} "
        f"{node.get('zt_ip',''):<16} "
        f"{node.get('socks_port',''):<8} "
        f"{node.get('http_port',''):<8} "
        f"{node.get('status',''):<10} "
        f"{node.get('zt_node_id','')}"
    )
next_avail = data.get("next_available")
if next_avail:
    print("-" * 72)
    print(
        f"Next available:  SOCKS {next_avail.get('socks_port','')}  "
        f"HTTP {next_avail.get('http_port','')}"
    )
PY