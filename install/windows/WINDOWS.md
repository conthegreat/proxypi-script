# ProxyPi on Windows 10 / 11

Same `proxyscript.py` as the Pis. On Windows it runs in a Python venv under `C:\ProgramData\ProxyPi` and is kept up by a Windows service (WinSW), with Task Scheduler as fallback.

WSL and Docker are not used. They sleep and lose the virtual NIC.

## Operator — install

1. Use a **64-bit Windows 10 or 11 PC that stays plugged in 24/7**.
2. Wired Ethernet to the router if possible.
3. Right-click **PowerShell** → **Run as administrator**, then:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/join.ps1 | iex
```

4. Copy the **10-character ZeroTier Node ID**.
5. Register at https://proxypi.co.uk/join (hostname, email, node ID).
6. Wait for the activation email. Run that command in **Administrator PowerShell**, or run `activate.cmd` as Administrator and paste the token.

The installer:

- Installs official ZeroTier and joins network `664bb06760e47198`
- Installs Python 3.12 if needed, creates `C:\ProgramData\ProxyPi\venv`, installs `pyrad`
- Downloads `proxyscript.py`
- Turns off sleep/hibernate on mains power and sets lid-close to do nothing on AC

## Operator — after activation

| Item | Path / name |
|------|-------------|
| Install dir | `C:\ProgramData\ProxyPi` |
| Secrets | `C:\ProgramData\ProxyPi\proxy.env` (Administrators + SYSTEM only) |
| Logs | `C:\ProgramData\ProxyPi\logs\proxy.log` |
| Service | `ProxyPi` (Automatic, delayed, depends on `ZeroTierOneService`) |
| Heartbeat | Scheduled task `ProxyPiHeartbeat` every 2 minutes |

Sign-out is fine. Sleep, shutdown, and lid-close-to-sleep take the node offline.

Status:

```powershell
irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/status.ps1 | iex
```

Leave:

```powershell
$env:CONFIRM='yes'
irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/leave.ps1 | iex
```

## Ops — bring a Windows node live

Same as a Pi after join: ZeroTier Central approve, `/admin/join` approve (ports + token), send the **Windows** activation command, then HAProxy + FreeRADIUS client + IONOS public ports + IP quality + `proxies.status=active`.

Windows activation (token never includes `RADIUS_SECRET`):

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
$env:ACTIVATION_TOKEN='TOKEN'
$env:ACTIVATION_API_URL='https://proxypi.co.uk'
irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/activate.ps1 | iex
```

Hostname: treat it like any other exit (`gb-isp-area`). A `win-` prefix in MC2 is optional.

After they activate:

1. Confirm ZeroTier member is **OK** with a `10.147.17.x` address.
2. Confirm `ProxyPi` service is Running and SOCKS/HTTP listen on the assigned ports.
3. Run the usual onboard (RADIUS client + HAProxy frontends to that ZT IP).
4. Open the two public ports on the London firewall.
5. IP quality check, then mark live.

Windows Firewall on the host is opened for those two TCP ports by `activate.ps1`.
