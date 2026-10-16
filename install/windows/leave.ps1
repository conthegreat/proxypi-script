# Stop the Windows proxy, drop local secrets, leave ZeroTier.
#   $env:CONFIRM='yes'; irm .../install/windows/leave.ps1 | iex
$ErrorActionPreference = "Stop"
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
Require-Admin

if ($env:CONFIRM -ne "yes") {
    Write-Host "This stops the proxy on this PC and leaves the ProxyPi ZeroTier network."
    Write-Host "Type YES to continue."
    $ans = Read-Host "Confirm"
    if ($ans -ne "YES") { Write-Die "Aborted." }
}

$InstallDir = Get-InstallDir
$NetworkId = "664bb06760e47198"

$exe = Join-Path $InstallDir "bin\ProxyPiService.exe"
if (Test-Path $exe) {
    Write-Info "Stopping ProxyPi service"
    & $exe stop 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $exe uninstall 2>$null | Out-Null
}
Get-Service ProxyPi -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
    sc.exe delete ProxyPi | Out-Null
}
Unregister-ScheduledTask -TaskName "ProxyPiProxy" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ProxyPiHeartbeat" -Confirm:$false -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName "ProxyPi SOCKS" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName "ProxyPi HTTP" -ErrorAction SilentlyContinue | Remove-NetFirewallRule

$cli = Get-ZeroTierCli
if ($cli) {
    Write-Info "Leaving ZeroTier network"
    & $cli leave $NetworkId | Out-Null
}

$envPath = Join-Path $InstallDir "proxy.env"
if (Test-Path $envPath) {
    Write-Info "Removing local secrets"
    Remove-Item $envPath -Force
}

if ($env:LEAVE_PURGE -eq "1") {
    Write-Info "Removing $InstallDir"
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Ok "This PC is no longer serving ProxyPi traffic."
Write-Host "Email support@proxypi.co.uk so public routing can be removed."
