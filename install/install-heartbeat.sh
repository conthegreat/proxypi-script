#!/usr/bin/env bash
# Install / refresh Pi resource heartbeat (for new activates and existing Pis).
#
# New activates: called from activate.sh automatically when HEARTBEAT_* present.
# Existing Pis:
#   1) On London mint a token (admin):
#        curl -s -X POST http://127.0.0.1:5001/pi/heartbeat/mint \
#          -H "X-Admin-Token: $PI_HEARTBEAT_ADMIN_TOKEN" \
#          -H "Content-Type: application/json" \
#          -d '{"zt_node_id":"YOUR_ZT_ID"}'
#   2) On the Pi:
#        curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/install-heartbeat.sh | \
#          HEARTBEAT_URL='http://10.147.17.33:5001/pi/heartbeat' \
#          HEARTBEAT_TOKEN='...' bash
set -euo pipefail

REPO_RAW="${PROXYPI_REPO_RAW:-https://raw.githubusercontent.com/conthegreat/proxypi-script/main}"
# When piped via curl|bash, BASH_SOURCE may be unset under `set -u`
SCRIPT_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
fi

die() { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }

detect_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  else
    id -un
  fi
}

RUN_USER="$(detect_user)"
HOME_DIR="$(eval echo "~${RUN_USER}")"
INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME_DIR}/proxy}"
PROXY_ENV="${INSTALL_DIR}/proxy.env"

mkdir -p "${INSTALL_DIR}"

# Prefer local copy when piped from repo checkout; else download
if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/pi_heartbeat.sh" ]]; then
  cp -f "${SCRIPT_DIR}/pi_heartbeat.sh" "${INSTALL_DIR}/pi_heartbeat.sh"
else
  info "Downloading pi_heartbeat.sh"
  curl -fsSL "${REPO_RAW}/install/pi_heartbeat.sh" -o "${INSTALL_DIR}/pi_heartbeat.sh"
fi
chmod 755 "${INSTALL_DIR}/pi_heartbeat.sh"

# Write / merge HEARTBEAT_* into proxy.env
HEARTBEAT_URL="${HEARTBEAT_URL:-http://10.147.17.33:5001/pi/heartbeat}"
HEARTBEAT_TOKEN="${HEARTBEAT_TOKEN:-}"

if [[ ! -f "${PROXY_ENV}" ]]; then
  umask 077
  touch "${PROXY_ENV}"
  chmod 600 "${PROXY_ENV}"
fi

# Remove old HEARTBEAT lines then append
tmp="$(mktemp)"
grep -vE '^(HEARTBEAT_URL|HEARTBEAT_TOKEN)=' "${PROXY_ENV}" >"${tmp}" || true
{
  cat "${tmp}"
  echo "HEARTBEAT_URL=${HEARTBEAT_URL}"
  if [[ -n "${HEARTBEAT_TOKEN}" ]]; then
    echo "HEARTBEAT_TOKEN=${HEARTBEAT_TOKEN}"
  elif grep -q '^HEARTBEAT_TOKEN=' "${PROXY_ENV}" 2>/dev/null; then
    grep '^HEARTBEAT_TOKEN=' "${PROXY_ENV}"
  else
    die "HEARTBEAT_TOKEN is required (from activate redeem or mint API)"
  fi
} >"${PROXY_ENV}"
rm -f "${tmp}"
chmod 600 "${PROXY_ENV}"
ok "Updated ${PROXY_ENV}"

# Install systemd unit + timer
UNIT_SVC=/etc/systemd/system/proxypi-heartbeat.service
UNIT_TMR=/etc/systemd/system/proxypi-heartbeat.timer

sudo tee "${UNIT_SVC}" >/dev/null <<EOF
[Unit]
Description=ProxyPi resource heartbeat (one-shot)
After=network-online.target zerotier-one.service
Wants=network-online.target

[Service]
Type=oneshot
User=${RUN_USER}
Group=${RUN_USER}
EnvironmentFile=-${INSTALL_DIR}/proxy.env
ExecStart=/bin/bash ${INSTALL_DIR}/pi_heartbeat.sh
Nice=10

[Install]
WantedBy=multi-user.target
EOF

sudo tee "${UNIT_TMR}" >/dev/null <<EOF
[Unit]
Description=Run ProxyPi resource heartbeat every 2 minutes

[Timer]
OnBootSec=90
OnUnitActiveSec=120
AccuracySec=30
Persistent=true
Unit=proxypi-heartbeat.service

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now proxypi-heartbeat.timer
ok "Heartbeat timer enabled (every 2 minutes)"

# Fire once now
sudo systemctl start proxypi-heartbeat.service || warn_fail=1
if [[ "${warn_fail:-0}" == "1" ]]; then
  echo "[!] Immediate heartbeat failed — check token/URL and journalctl -u proxypi-heartbeat.service"
else
  ok "Initial heartbeat sent"
fi
