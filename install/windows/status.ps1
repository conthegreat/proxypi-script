# Show ZeroTier, service, and listener status on a Windows ProxyPi node.
$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Import-ProxyPiCommon {
    $install = if ($env:PROXYPI_INSTALL_DIR) { $env:PROXYPI_INSTALL_DIR } else { Join-Path $env:ProgramData "ProxyPi" }
    $onDisk = Join-Path $install "common.ps1"
    if (Test-Path $onDisk) { . $onDisk; return }
    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "common.ps1"))) { . (Join-Path $PSScriptRoot "common.ps1"); return }
    $raw = "https://raw.githubusercontent.com/conthegreat/proxypi-script/main"
    $tmp = Join-Path $env:TEMP "proxypi-common.ps1"
    Invoke-WebRequest -Uri "$raw/install/windows/common.ps1" -OutFile $tmp -UseBasicParsing
    . $tmp
}
Import-ProxyPiCommon
$InstallDir = Get-InstallDir

Write-Host "=== Install dir ==="
Write-Host $InstallDir
Write-Host ""
Write-Host "=== ZeroTier ==="
$cli = Get-ZeroTierCli
if ($cli) {
    Write-Host "CLI: $cli"
    Write-Host (Invoke-ZeroTier "info").Text
    Write-Host (Invoke-ZeroTier "listnetworks").Text
} else {
    Write-Host "ZeroTier not installed"
}
Write-Host "=== Node info ==="
$info = Join-Path $InstallDir "node-info.env"
if (Test-Path $info) { Get-Content $info } else { Write-Host "Not found: $info" }
Write-Host ""
Write-Host "=== Service ==="
Get-Service ProxyPi, ZeroTierOneService -ErrorAction SilentlyContinue | Format-Table Name, Status, StartType -AutoSize
Write-Host "=== Listening ports ==="
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -ge 18000 -and $_.LocalPort -le 59999 } |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Format-Table -AutoSize
Write-Host "=== Recent log ==="
$log = Join-Path $InstallDir "logs\proxy.log"
if (Test-Path $log) { Get-Content $log -Tail 20 } else { Write-Host "No proxy.log yet" }
