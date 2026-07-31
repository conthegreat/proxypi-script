#!/usr/bin/env bash
# Leave / uninstall ProxyPi on this device (operator self-service).
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/leave.sh | bash
#
# Non-interactive:
#   curl -fsSL .../leave.sh | CONFIRM=yes bash
#
# Options (env):
#   CONFIRM=yes              skip interactive prompt
#   LEAVE_PURGE=1            also delete ~/proxy install tree (keeps logs unless LEAVE_WIPE_LOGS=1)
#   LEAVE_WIPE_LOGS=1        remove /var/log/proxy if present
#   LEAVE_REMOVE_ZT=1        leave network AND uninstall ZeroTier package
#   LEAVE_KEEP_ZT=1          stop proxy only; stay on ZeroTier network
#   LEAVE_NOTIFY_URL=...     optional POST JSON after local cleanup (ops webhook)
#   PROXYPI_INSTALL_DIR=...  default: $HOME/proxy
#   PROXYPI_SERVICE_NAME=... default: improved_proxy.service
#
# This script only cleans the Pi. FreeRADIUS / HAProxy / UFW / SQL / ZT authorize
# on ProxyPi servers are removed by ops (Mission Control onboard reverse / manual).
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
SERVICE_NAME="${PROXYPI_SERVICE_NAME:-improved_proxy.service}"
NODE_INFO="${INSTALL_DIR}/node-info.env"
PROXY_ENV="${INSTALL_DIR}/proxy.env"
CONFIG_FILE="${INSTALL_DIR}/config.defaults"
ZT_NWID="${ZEROTIER_NETWORK_ID:-664bb06760e47198}"

CONFIRM="${CONFIRM:-}"
LEAVE_PURGE="${LEAVE_PURGE:-0}"
LEAVE_WIPE_LOGS="${LEAVE_WIPE_LOGS:-0}"
LEAVE_REMOVE_ZT="${LEAVE_REMOVE_ZT:-0}"
LEAVE_KEEP_ZT="${LEAVE_KEEP_ZT:-0}"
LEAVE_NOTIFY_URL="${LEAVE_NOTIFY_URL:-}"

die() { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}" || true
  ZT_NWID="${ZEROTIER_NETWORK_ID:-$ZT_NWID}"
fi

HOSTNAME_VAL="$(hostname 2>/dev/null || echo unknown)"
ZT_NODE_ID=""
if [[ -f "${NODE_INFO}" ]]; then
  # shellcheck disable=SC1090
  source "${NODE_INFO}" || true
  ZT_NODE_ID="${ZEROTIER_NODE_ID:-${ZT_NODE_ID:-${NODE_ID:-}}}"
fi
if [[ -z "${ZT_NODE_ID}" ]] && command -v zerotier-cli >/dev/null 2>&1; then
  ZT_NODE_ID="$(sudo zerotier-cli info 2>/dev/null | awk '{print $3}' || true)"
fi

echo ""
echo "=============================================="
echo "  ProxyPi — leave network / remove this node"
echo "=============================================="
echo "  Host:       ${HOSTNAME_VAL}"
echo "  Install:    ${INSTALL_DIR}"
echo "  Service:    ${SERVICE_NAME}"
echo "  ZT network: ${ZT_NWID}"
echo "  ZT node id: ${ZT_NODE_ID:-unknown}"
echo "=============================================="
echo ""
echo "This will:"
echo "  1. Stop and disable the proxy service"
echo "  2. Remove local secrets (proxy.env)"
if [[ "${LEAVE_KEEP_ZT}" == "1" ]]; then
  echo "  3. Leave ZeroTier network: NO (LEAVE_KEEP_ZT=1)"
else
  echo "  3. Leave ZeroTier network ${ZT_NWID}"
fi
if [[ "${LEAVE_REMOVE_ZT}" == "1" ]]; then
  echo "  4. Uninstall ZeroTier package"
fi
if [[ "${LEAVE_PURGE}" == "1" ]]; then
  echo "  5. Delete install directory ${INSTALL_DIR}"
fi
echo ""
echo "Server-side (RADIUS / public ports / DNS / pool) is NOT removed by this"
echo "script — email support@proxypi.co.uk so ops can finish offboarding."
echo ""

if [[ "${CONFIRM}" != "yes" && "${CONFIRM}" != "YES" ]]; then
  if [[ ! -t 0 ]]; then
    die "Non-interactive shell: re-run with CONFIRM=yes (this is destructive)."
  fi
  read -r -p "Type YES to leave the ProxyPi network on this device: " ans
  [[ "${ans}" == "YES" ]] || die "Aborted (typed '${ans}', expected YES)."
fi

# --- 1) Stop proxy ---
if systemctl list-unit-files "${SERVICE_NAME}" >/dev/null 2>&1 \
  || systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
  info "Stopping ${SERVICE_NAME}"
  sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  ok "Service stopped and disabled"
else
  warn "Service ${SERVICE_NAME} not found (already removed?)"
fi

# Drop unit file if installed under /etc/systemd
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
if [[ -f "${UNIT_PATH}" ]]; then
  info "Removing unit ${UNIT_PATH}"
  sudo rm -f "${UNIT_PATH}"
  sudo systemctl daemon-reload
  ok "Unit removed"
fi

# --- 2) Secrets ---
if [[ -f "${PROXY_ENV}" ]]; then
  info "Shredding ${PROXY_ENV}"
  if command -v shred >/dev/null 2>&1; then
    shred -u "${PROXY_ENV}" 2>/dev/null || rm -f "${PROXY_ENV}"
  else
    rm -f "${PROXY_ENV}"
  fi
  ok "Local RADIUS/proxy secrets removed"
fi

if [[ -f "${NODE_INFO}" ]]; then
  {
    echo "STATUS=left"
    echo "LEFT_AT=$(date -Iseconds 2>/dev/null || date)"
  } >> "${NODE_INFO}" 2>/dev/null || true
fi

# --- 3) ZeroTier leave ---
if [[ "${LEAVE_KEEP_ZT}" != "1" ]]; then
  if command -v zerotier-cli >/dev/null 2>&1; then
    info "Leaving ZeroTier network ${ZT_NWID}"
    sudo zerotier-cli leave "${ZT_NWID}" >/dev/null 2>&1 || warn "leave returned non-zero (maybe already left)"
    ok "Left network ${ZT_NWID}"
    sudo zerotier-cli listnetworks 2>/dev/null || true
  else
    warn "zerotier-cli not found — skip leave"
  fi
fi

if [[ "${LEAVE_REMOVE_ZT}" == "1" ]]; then
  info "Removing ZeroTier package"
  if command -v apt-get >/dev/null 2>&1; then
    sudo systemctl stop zerotier-one 2>/dev/null || true
    sudo apt-get remove -y zerotier-one 2>/dev/null || true
    ok "ZeroTier package removal attempted"
  else
    warn "apt-get not available — remove ZeroTier manually"
  fi
fi

# --- 4) Optional purge install ---
if [[ "${LEAVE_PURGE}" == "1" ]]; then
  if [[ -d "${INSTALL_DIR}" ]]; then
    info "Removing ${INSTALL_DIR}"
    rm -rf "${INSTALL_DIR}"
    ok "Install directory removed"
  fi
fi

if [[ "${LEAVE_WIPE_LOGS}" == "1" ]]; then
  if [[ -d /var/log/proxy ]]; then
    info "Removing /var/log/proxy"
    sudo rm -rf /var/log/proxy
    ok "Logs removed"
  fi
fi

# --- 5) Optional notify ops ---
if [[ -n "${LEAVE_NOTIFY_URL}" ]]; then
  info "Notifying ${LEAVE_NOTIFY_URL}"
  payload=$(printf '{"event":"leave","hostname":"%s","zt_node_id":"%s","left_at":"%s"}' \
    "${HOSTNAME_VAL}" "${ZT_NODE_ID}" "$(date -Iseconds 2>/dev/null || date)")
  curl -fsS -X POST "${LEAVE_NOTIFY_URL}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    --connect-timeout 10 --max-time 30 \
    && ok "Notify sent" || warn "Notify failed (local leave still done)"
fi

echo ""
ok "Local leave complete on ${HOSTNAME_VAL}."
echo ""
echo "Please email support@proxypi.co.uk with:"
echo "  • Subject: Leave network — ${HOSTNAME_VAL}"
echo "  • ZeroTier node id: ${ZT_NODE_ID:-unknown}"
echo "  • Approx leave time: $(date -u +%Y-%m-%dT%H:%MZ)"
echo ""
echo "Ops will remove this node from the public pool (HAProxy ports, FreeRADIUS,"
echo "firewall, DNS, and payment eligibility)."
echo ""
echo "Optional full purge later:"
echo "  curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/leave.sh | \\"
echo "    CONFIRM=yes LEAVE_PURGE=1 LEAVE_REMOVE_ZT=1 bash"
echo ""
