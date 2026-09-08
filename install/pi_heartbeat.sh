#!/usr/bin/env bash
# Collect Pi resource metrics and POST to ProxyPi London (ZT).
# Installed by activate.sh / install-heartbeat.sh. Runs via systemd timer.
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
PROXY_ENV="${INSTALL_DIR}/proxy.env"
NODE_INFO="${INSTALL_DIR}/node-info.env"

[[ -f "${PROXY_ENV}" ]] || exit 0
# shellcheck disable=SC1090
source "${PROXY_ENV}"

HEARTBEAT_URL="${HEARTBEAT_URL:-}"
HEARTBEAT_TOKEN="${HEARTBEAT_TOKEN:-}"
[[ -n "${HEARTBEAT_URL}" && -n "${HEARTBEAT_TOKEN}" ]] || exit 0

HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"
ZT_NODE_ID=""
ZT_IP=""
if [[ -f "${NODE_INFO}" ]]; then
  # shellcheck disable=SC1090
  source "${NODE_INFO}" || true
  ZT_NODE_ID="${ZT_NODE_ID:-${ZEROTIER_NODE_ID:-}}"
  ZT_IP="${ZT_IP:-}"
fi
# node-info often has ZT_IP=pending before approval — treat as empty
if [[ -z "${ZT_IP}" || "${ZT_IP}" == "pending" ]]; then
  ZT_IP="$(ip -4 addr show 2>/dev/null | awk '/inet 10\.147\./ {print $2}' | cut -d/ -f1 | head -1 || true)"
fi

# Metrics (best-effort; missing tools → null)
read -r MEM_TOTAL_KB MEM_AVAIL_KB <<<"$(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{print t+0, a+0}' /proc/meminfo 2>/dev/null || echo '0 0')"
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_AVAIL_MB=$(( MEM_AVAIL_KB / 1024 ))
MEM_PCT=""
if [[ "${MEM_TOTAL_MB}" -gt 0 ]]; then
  MEM_USED=$(( MEM_TOTAL_MB - MEM_AVAIL_MB ))
  MEM_PCT="$(awk -v u="${MEM_USED}" -v t="${MEM_TOTAL_MB}" 'BEGIN{printf "%.1f", (u*100)/t}')"
fi

LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "")"
UPTIME_SEC="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "")"

# CPU % from /proc/stat sample
CPU_PCT=""
if [[ -r /proc/stat ]]; then
  read -r _ a b c d e f g h i j < <(grep '^cpu ' /proc/stat)
  idle1=$d; total1=$((a+b+c+d+e+f+g+h+i+j))
  sleep 0.4
  read -r _ a b c d e f g h i j < <(grep '^cpu ' /proc/stat)
  idle2=$d; total2=$((a+b+c+d+e+f+g+h+i+j))
  di=$((idle2-idle1)); dt=$((total2-total1))
  if [[ "${dt}" -gt 0 ]]; then
    CPU_PCT="$(awk -v di="${di}" -v dt="${dt}" 'BEGIN{printf "%.1f", (1-di/dt)*100}')"
  fi
fi

TEMP_C=""
if command -v vcgencmd >/dev/null 2>&1; then
  TEMP_C="$(vcgencmd measure_temp 2>/dev/null | tr -dc '0-9.' || true)"
elif [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  TEMP_C="$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)"
fi

DISK_PCT=""
DISK_PCT="$(df -P / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || true)"

CONNTRACK=""
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  CONNTRACK="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true)"
fi

PROXY_ACTIVE=0
systemctl is-active --quiet improved_proxy.service 2>/dev/null && PROXY_ACTIVE=1

SOCKS_LISTENING=0
SOCKS_PORT="${SOCKS_PORT:-}"
if [[ -n "${SOCKS_PORT}" ]]; then
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":${SOCKS_PORT}\$" && SOCKS_LISTENING=1
  fi
fi

PAYLOAD="$(HOSTNAME_VAL="${HOSTNAME_VAL}" ZT_NODE_ID="${ZT_NODE_ID}" ZT_IP="${ZT_IP}" \
CPU_PCT="${CPU_PCT}" MEM_TOTAL_MB="${MEM_TOTAL_MB}" MEM_AVAIL_MB="${MEM_AVAIL_MB}" MEM_PCT="${MEM_PCT}" \
TEMP_C="${TEMP_C}" DISK_PCT="${DISK_PCT}" LOAD1="${LOAD1}" CONNTRACK="${CONNTRACK}" \
PROXY_ACTIVE="${PROXY_ACTIVE}" SOCKS_LISTENING="${SOCKS_LISTENING}" UPTIME_SEC="${UPTIME_SEC}" \
python3 - <<'PY'
import json, os
def num(k):
    v = os.environ.get(k, "")
    if v == "" or v is None:
        return None
    try:
        if k.endswith("_MB") or k in ("CONNTRACK", "UPTIME_SEC", "DISK_PCT"):
            return int(float(v))
        return float(v)
    except Exception:
        return None
print(json.dumps({
  "hostname": os.environ.get("HOSTNAME_VAL") or None,
  "zt_node_id": os.environ.get("ZT_NODE_ID") or None,
  "zt_ip": os.environ.get("ZT_IP") or None,
  "cpu_pct": num("CPU_PCT"),
  "mem_total_mb": num("MEM_TOTAL_MB"),
  "mem_avail_mb": num("MEM_AVAIL_MB"),
  "mem_pct": num("MEM_PCT"),
  "temp_c": num("TEMP_C"),
  "disk_pct": num("DISK_PCT"),
  "load1": num("LOAD1"),
  "conntrack": num("CONNTRACK"),
  "proxy_active": os.environ.get("PROXY_ACTIVE") == "1",
  "socks_listening": os.environ.get("SOCKS_LISTENING") == "1",
  "uptime_sec": num("UPTIME_SEC"),
}))
PY
)"

curl -fsS -X POST "${HEARTBEAT_URL}" \
  -H "Authorization: Bearer ${HEARTBEAT_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --connect-timeout 8 \
  --max-time 20 \
  -d "${PAYLOAD}" >/dev/null
