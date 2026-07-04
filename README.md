# ProxyPi Join Script

One-command installer for joining the Network Contractor proxy network on a Raspberry Pi.

## For new Pi operators

On a fresh Raspberry Pi (Raspberry Pi OS / Debian):

```bash
curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/join.sh | bash
```

This will:

1. Install ZeroTier and join the network
2. Install Python dependencies (`pyrad`)
3. Download the proxy script into `~/proxy`
4. Install the `improved_proxy.service` systemd unit (not started yet)
5. Print your **ZeroTier Node ID** for approval

After the network operator approves your device in ZeroTier Central and assigns ports, run the activation command they send you:

```bash
curl -fsSL https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/activate.sh | \
  SOCKS_PORT=18100 HTTP_PORT=58100 RADIUS_SECRET='your-secret' bash
```

## For network operators (you)

### Network config (already set from pi audit)

| Setting | Value |
|---------|-------|
| ZeroTier network | `664bb06760e47198` (ProxyPi) |
| RADIUS server | `10.147.17.33` |
| Log directory | `/var/log/proxy` |

Keep `RADIUS_SECRET` out of the repo — pass it only in the activation command.

### When a new Pi requests to join

1. User runs `join.sh` and sends you their **ZeroTier Node ID**
2. Approve the device in [ZeroTier Central](https://my.zerotier.com/)
3. Assign ports:

```bash
git clone https://github.com/conthegreat/proxypi-script.git
cd proxypi-script/admin
RADIUS_SECRET='your-radius-secret' ./assign-ports.sh pi-3 <zt_node_id> <zt_ip>
```

4. Send the printed `activate.sh` curl command to the Pi operator
5. Commit the updated `ports-registry.json`

### List all nodes

```bash
./admin/list-nodes.sh
```

## Port allocation

Ports are tracked in `admin/ports-registry.json`. New nodes get non-conflicting pairs:

- SOCKS: `18000–18999`
- HTTP: `58000–59999` (offset +40000 from SOCKS where possible)

Existing nodes:

| Host | ZT Node ID | ZT IP | SOCKS | HTTP |
|------|------------|-------|-------|------|
| pi-1 | `92f3f49437` | 10.147.17.149 | 18721 | 58920 |
| pi-2 | `4da4adb76f` | 10.147.17.68 | 17812 | 59802 |

Next new node: **SOCKS 18100 / HTTP 58100**

## Audited Pi requirements

Confirmed by SSH on your live Pis:

- **OS:** Debian 12/13 (Raspberry Pi OS)
- **ZeroTier:** `curl install.zerotier.com | bash`, join network `664bb06760e47198`
- **Python:** `python3`, `python3-venv`, `python3-pip`
- **Pip packages:** `pyrad>=2.4` (installs `netaddr`, `six`)
- **Proxy:** `~/proxy/proxyscript.py` in a venv, `improved_proxy.service`
- **RADIUS dictionary:** auto-created beside the script (no `/etc/freeradius` fallback)
- **Logs:** `/var/log/proxy/` (CSV + `proxy.log`)

## Files on the Pi after install

| Path | Purpose |
|------|---------|
| `~/proxy/proxyscript.py` | Main proxy (SOCKS5 + HTTP, RADIUS auth/accounting) |
| `~/proxy/venv/` | Python virtual environment |
| `~/proxy/proxy.env` | Ports and secrets (created at activation, mode 600) |
| `~/proxy/node-info.env` | Hostname, ZT node ID, status |
| `/var/log/proxy/` | Logs and CSV usage files |

## Security notes

- `RADIUS_SECRET` is never stored in this public repo
- `proxy.env` is chmod 600 and only readable by the Pi user
- ZeroTier network ID is public (required to join) — this is normal
- Approve new devices manually in ZeroTier Central before activation

## Manual service control

```bash
sudo systemctl status improved_proxy.service
sudo systemctl restart improved_proxy.service
journalctl -u improved_proxy.service -f
tail -f /var/log/proxy/proxy.log
```