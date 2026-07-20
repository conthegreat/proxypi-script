#!/usr/bin/env bash
# Activates the proxy after ZeroTier approval and port assignment.
#
# Preferred (token redeem — RADIUS secret never in email):
#   curl -fsSL .../install/activate.sh | \
#     ACTIVATION_TOKEN='...' ACTIVATION_API_URL='https://proxypi.co.uk' bash
#
# Legacy (manual — secret on the command line):
#   curl -fsSL .../install/activate.sh | \
#     SOCKS_PORT=18100 HTTP_PORT=58100 RADIUS_SECRET='secret' bash
set -euo pipefail

INSTALL_DIR="${PROXYPI_INSTALL_DIR:-${HOME}/proxy}"
SERVICE_NAME="${PROXYPI_SERVICE_NAME:-improved_proxy.service}"
PROXY_ENV="${INSTALL_DIR}/proxy.env"
NODE_INFO="${INSTALL_DIR}/node-info.env"
CONFIG_FILE="${INSTALL_DIR}/config.defaults"

die() { echo "[-] $*" >&2; exit 1; }
info() { echo "[*] $*"; }
ok() { echo "[+] $*"; }

[[ -f "${INSTALL_DIR}/proxyscript.py" ]] \
  || die "Proxy not installed. Run join.sh first."

ACTIVATION_TOKEN="${ACTIVATION_TOKEN:-}"
ACTIVATION_API_URL="${ACTIVATION_API_URL:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
HTTP_PORT="${HTTP_PORT:-}"
RADIUS_SECRET="${RADIUS_SECRET:-}"
RADIUS_SERVER="${RADIUS_SERVER:-10.147.17.33}"
PROXY_LOG_DIR="${PROXY_LOG_DIR:-/var/log/proxy}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

# Optional binding check from node-info.env
ZT_NODE_ID=""
if [[ -f "${NODE_INFO}" ]]; then
  # shellcheck disable=SC1090
  source "${NODE_INFO}" || true
  ZT_NODE_ID="${ZEROTIER_NODE_ID:-${ZT_NODE_ID:-${NODE_ID:-}}}"
fi

redeem_activation_token() {
  local api_base token
  api_base="${ACTIVATION_API_URL%/}"
  token="${ACTIVATION_TOKEN}"
  [[ -n "${api_base}" ]] || die "ACTIVATION_API_URL is required for token activation"
  [[ -n "${token}" ]] || die "ACTIVATION_TOKEN is required for token activation"

  local url="${api_base}/join/activate/redeem"
  info "Redeeming activation token via ${url}"

  local payload tmp_body http_code
  payload=$(printf '{"token":"%s","zt_node_id":"%s"}' "${token}" "${ZT_NODE_ID}")
  tmp_body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp_body}'" RETURN

  http_code="$(
    curl -sS -o "${tmp_body}" -w "%{http_code}" \
      -X POST "${url}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --connect-timeout 15 \
      --max-time 60 \
      -d "${payload}"
  )" || die "Failed to contact activation API at ${url}"

  if [[ "${http_code}" != "200" ]]; then
    local err
    err="$(tr -d '\r' <"${tmp_body}" | head -c 500)"
    die "Activation redeem failed (HTTP ${http_code}): ${err}"
  fi

  # Prefer python for JSON (present on ProxyPi images); fall back to grep/sed-ish via python only.
  if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    die "python3 is required to parse activation API response"
  fi
  local py
  py="$(command -v python3 || command -v python)"

  eval "$(
    "${py}" - "${tmp_body}" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
required = ("socks_port", "http_port", "radius_secret")
missing = [k for k in required if not data.get(k)]
if missing:
    print(f'echo "[-] Activation response missing: {", ".join(missing)}" >&2; exit 1')
    sys.exit(0)
def sh_escape(value):
    return "'" + str(value).replace("'", "'\"'\"'") + "'"
print(f"SOCKS_PORT={sh_escape(data['socks_port'])}")
print(f"HTTP_PORT={sh_escape(data['http_port'])}")
print(f"RADIUS_SECRET={sh_escape(data['radius_secret'])}")
if data.get("radius_server"):
    print(f"RADIUS_SERVER={sh_escape(data['radius_server'])}")
if data.get("hostname"):
    print(f"REDEEM_HOSTNAME={sh_escape(data['hostname'])}")
print("export SOCKS_PORT HTTP_PORT RADIUS_SECRET RADIUS_SERVER")
PY
  )" || die "Invalid activation API response"
  ok "Token redeemed — ports and RADIUS credentials received (secret not shown)"
}

if [[ -n "${ACTIVATION_TOKEN}" ]]; then
  redeem_activation_token
fi

[[ -n "${SOCKS_PORT}" ]] || die "SOCKS_PORT is required (via token redeem or env)"
[[ -n "${HTTP_PORT}" ]] || die "HTTP_PORT is required (via token redeem or env)"
[[ -n "${RADIUS_SECRET}" ]] || die "RADIUS_SECRET is required (via token redeem or env)"

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln | awk '{print $4}' | grep -q ":${port}\$"
  else
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"
  fi
}

port_in_use "${SOCKS_PORT}" && die "SOCKS port ${SOCKS_PORT} is already in use on this host"
port_in_use "${HTTP_PORT}" && die "HTTP port ${HTTP_PORT} is already in use on this host"

umask 077
cat >"${PROXY_ENV}" <<EOF
SOCKS_PORT=${SOCKS_PORT}
HTTP_PORT=${HTTP_PORT}
RADIUS_SERVER=${RADIUS_SERVER}
RADIUS_SECRET=${RADIUS_SECRET}
PROXY_LOG_DIR=${PROXY_LOG_DIR}
EOF
chmod 600 "${PROXY_ENV}"
ok "Wrote ${PROXY_ENV} (mode 600)"

if [[ -f "${NODE_INFO}" ]]; then
  sed -i 's/^STATUS=.*/STATUS=active/' "${NODE_INFO}" 2>/dev/null || true
  {
    echo "SOCKS_PORT=${SOCKS_PORT}"
    echo "HTTP_PORT=${HTTP_PORT}"
    echo "ACTIVATED_AT=$(date -Iseconds 2>/dev/null || date)"
  } >> "${NODE_INFO}"
fi

info "Enabling and starting ${SERVICE_NAME}"
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"
sleep 2

if sudo systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "Proxy is running"
  echo "    SOCKS: 0.0.0.0:${SOCKS_PORT}"
  echo "    HTTP:  0.0.0.0:${HTTP_PORT}"
  echo "    RADIUS server: ${RADIUS_SERVER}"
  sudo systemctl status "${SERVICE_NAME}" --no-pager -n 5
else
  die "Service failed to start. Check: journalctl -u ${SERVICE_NAME} -n 50"
fi
