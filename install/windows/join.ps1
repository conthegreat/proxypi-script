# ProxyPi Windows join — one-line installer.
# Run in PowerShell as Administrator:
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/join.ps1 | iex
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$raw = if ($env:PROXYPI_REPO_URL) { $env:PROXYPI_REPO_URL.TrimEnd("/") } else { "https://raw.githubusercontent.com/conthegreat/proxypi-script/main" }
$setup = Join-Path $env:TEMP ("proxypi-setup-" + [guid]::NewGuid().ToString("n") + ".ps1")
Invoke-WebRequest -Uri "$raw/install/windows/setup.ps1" -OutFile $setup -UseBasicParsing
try {
    & $setup
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Remove-Item $setup -Force -ErrorAction SilentlyContinue
}
