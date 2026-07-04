# ProxyPi Port Registry

Live port assignments for the ProxyPi ZeroTier network (`664bb06760e47198`).

**Source of truth:** `ports-registry.json` — update via `assign-ports.sh` when onboarding new nodes.

| Host | ZT IP | ZT Node ID | SOCKS | HTTP | Status | Layout |
|------|-------|------------|-------|------|--------|--------|
| pi-1 | 10.147.17.149 | `92f3f49437` | **18721** | **58920** | active | `~/proxy` + venv |
| pi-2 | 10.147.17.68 | `4da4adb76f` | **17812** | **59802** | active | `~/proxy` + venv |

**Next available (new nodes):** SOCKS `18100` / HTTP `58100`

## Port ranges for new assignments

| Type | Range |
|------|-------|
| SOCKS | 18000 – 18999 |
| HTTP | 58000 – 59999 |

## Commands

```bash
./admin/list-nodes.sh          # table view from registry
./admin/onboard.sh             # wizard for new Pi after ZT approval
./admin/assign-ports.sh ...    # assign ports only
```