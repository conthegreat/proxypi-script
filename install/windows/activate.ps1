# Redeem one-time token, write proxy.env, install Windows service, start proxy.
# Elevated PowerShell:
#   $env:ACTIVATION_TOKEN='...'; $env:ACTIVATION_API_URL='https://proxypi.co.uk'
#   irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/activate.ps1 | iex
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Import-ProxyPiCommon {
    $raw = if ($env:PROXYPI_REPO_URL) { $env:PROXYPI_REPO_URL.TrimEnd("/") } else { "https://raw.githubusercontent.com/conthegreat/proxypi-script/main" }
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot "common.ps1"
        if (Test-Path $local) { . $local; return }
    }
    $install = if ($env:PROXYPI_INSTALL_DIR) { $env:PROXYPI_INSTALL_DIR } else { Join-Path $env:ProgramData "ProxyPi" }
    $onDisk = Join-Path $install "common.ps1"
    if (Test-Path $onDisk) { . $onDisk; return }
    $tmp = Join-Path $env:TEMP "proxypi-common.ps1"
    Invoke-WebRequest -Uri "$raw/install/windows/common.ps1" -OutFile $tmp -UseBasicParsing
    . $tmp
}

Import-ProxyPiCommon
Require-Admin
Require-Windows64

$RepoRaw = Get-RepoRaw
$InstallDir = Get-InstallDir
$WinSwUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
$Token = $env:ACTIVATION_TOKEN
$ApiUrl = $env:ACTIVATION_API_URL
if (-not $ApiUrl) { $ApiUrl = "https://proxypi.co.uk" }
$ApiUrl = $ApiUrl.TrimEnd("/")

if (-not (Test-Path (Join-Path $InstallDir "proxyscript.py"))) {
    Write-Die "Proxy not installed. Run the Windows join command first."
}
if (-not $Token) { Write-Die "ACTIVATION_TOKEN is required." }

function Redeem-Token {
    $nodeId = Get-ZeroTierNodeId
    $payload = @{ token = $Token; zt_node_id = $nodeId } | ConvertTo-Json -Compress
    $url = "$ApiUrl/join/activate/redeem"
    Write-Info "Redeeming activation token via $url"
    try {
        $resp = Invoke-RestMethod -Method POST -Uri $url -ContentType "application/json" -Body $payload -TimeoutSec 60
    } catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
        Write-Die "Activation redeem failed: $detail"
    }
    if (-not $resp.socks_port -or -not $resp.http_port -or -not $resp.radius_secret) {
        Write-Die "Activation response missing ports or credentials."
    }
    Write-Ok "Token redeemed — ports and RADIUS credentials received (secret not shown)"
    return $resp
}

function Write-ProxyEnv($resp) {
    $logDir = Join-Path $InstallDir "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $radiusServer = $resp.radius_server
    if (-not $radiusServer) { $radiusServer = "10.147.17.33" }
    $dns = if ($env:PROXY_DNS_SERVERS) { $env:PROXY_DNS_SERVERS } else { "10.147.17.33,1.1.1.1" }
    $lines = @(
        "SOCKS_PORT=$($resp.socks_port)",
        "HTTP_PORT=$($resp.http_port)",
        "RADIUS_SERVER=$radiusServer",
        "RADIUS_SECRET=$($resp.radius_secret)",
        "PROXY_LOG_DIR=$logDir",
        "PROXY_DNS_SERVERS=$dns",
        "PROXY_DNS_TIMEOUT=3"
    )
    $hbUrl = $resp.heartbeat_url
    $hbTok = $resp.heartbeat_token
    if ($hbUrl -and $hbTok) {
        $lines += "HEARTBEAT_URL=$hbUrl"
        $lines += "HEARTBEAT_TOKEN=$hbTok"
    }
    $envPath = Join-Path $InstallDir "proxy.env"
    ($lines -join "`r`n") + "`r`n" | Set-Content -Path $envPath -Encoding ASCII
    Protect-SecretFile $envPath
    Write-Ok "Wrote $envPath"
}

function Open-Firewall([int]$Socks, [int]$Http) {
    Write-Info "Allowing inbound TCP $Socks / $Http (ZeroTier + local) in Windows Firewall"
    foreach ($pair in @(@{ Name = "ProxyPi SOCKS"; Port = $Socks }, @{ Name = "ProxyPi HTTP"; Port = $Http })) {
        Get-NetFirewallRule -DisplayName $pair.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $pair.Name -Direction Inbound -Protocol TCP -LocalPort $pair.Port -Action Allow -Profile Any | Out-Null
    }
}

function Install-WinSwService {
    $bin = Join-Path $InstallDir "bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $exe = Join-Path $bin "ProxyPiService.exe"
    $xml = Join-Path $bin "ProxyPiService.xml"
    Write-Info "Installing ProxyPi Windows service (WinSW)"
    Download-File $WinSwUrl $exe
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $run = Join-Path $InstallDir "run-proxy.ps1"
    @"
<service>
  <id>ProxyPi</id>
  <name>ProxyPi</name>
  <description>ProxyPi UK residential SOCKS5/HTTP node</description>
  <executable>$ps</executable>
  <arguments>-NoProfile -ExecutionPolicy Bypass -File "$run"</arguments>
  <workingdirectory>$InstallDir</workingdirectory>
  <logpath>$(Join-Path $InstallDir "logs")</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>4</keepFiles>
  </log>
  <onfailure action="restart" delay="5 sec"/>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <resetfailure>1 hour</resetfailure>
  <depend>ZeroTierOneService</depend>
  <startmode>Automatic</startmode>
  <delayedAutoStart>true</delayedAutoStart>
</service>
"@ | Set-Content -Path $xml -Encoding ASCII
    $existing = Get-Service -Name "ProxyPi" -ErrorAction SilentlyContinue
    if ($existing) {
        & $exe stop 2>$null | Out-Null
        Start-Sleep -Seconds 2
        & $exe uninstall 2>$null | Out-Null
        Start-Sleep -Seconds 1
    }
    & $exe install
    if ($LASTEXITCODE -ne 0) { throw "WinSW install failed ($LASTEXITCODE)" }
    sc.exe config ProxyPi start= delayed-auto | Out-Null
    & $exe start
    Start-Sleep -Seconds 3
    $svc = Get-Service -Name "ProxyPi" -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne "Running") {
        throw "ProxyPi service did not start"
    }
    Write-Ok "Windows service ProxyPi is running"
}

function Install-TaskFallback {
    Write-Warn "WinSW service install failed — using Task Scheduler fallback"
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $run = Join-Path $InstallDir "run-proxy.ps1"
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$run`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "ProxyPiProxy" -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName "ProxyPiProxy"
    Write-Ok "Scheduled task ProxyPiProxy started"
}

function Install-HeartbeatTask {
    $hb = Join-Path $InstallDir "heartbeat.ps1"
    if (-not (Test-Path $hb)) {
        Download-File "$RepoRaw/install/windows/heartbeat.ps1" $hb
    }
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$hb`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 9999)
    $boot = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName "ProxyPiHeartbeat" -Action $action -Trigger @($trigger, $boot) -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName "ProxyPiHeartbeat" -ErrorAction SilentlyContinue
    Write-Ok "Heartbeat task every 2 minutes"
}

function Test-Listening([int]$Port) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$c
}

$resp = Redeem-Token
Write-ProxyEnv $resp
$socks = [int]$resp.socks_port
$http = [int]$resp.http_port
Open-Firewall $socks $http

$nodeInfo = Join-Path $InstallDir "node-info.env"
if (Test-Path $nodeInfo) {
    $stamp = Get-Date -Format o
    Add-Content -Path $nodeInfo -Encoding ASCII -Value "SOCKS_PORT=$socks"
    Add-Content -Path $nodeInfo -Encoding ASCII -Value "HTTP_PORT=$http"
    Add-Content -Path $nodeInfo -Encoding ASCII -Value "ACTIVATED_AT=$stamp"
    (Get-Content $nodeInfo) -replace '^STATUS=.*', 'STATUS=active' | Set-Content $nodeInfo -Encoding ASCII
}

try {
    Install-WinSwService
} catch {
    Write-Warn $_.Exception.Message
    Install-TaskFallback
}

try { Install-HeartbeatTask } catch { Write-Warn "Heartbeat install deferred: $($_.Exception.Message)" }

Start-Sleep -Seconds 2
$socksUp = Test-Listening $socks
$httpUp = Test-Listening $http
if ($socksUp -and $httpUp) {
    Write-Ok "Proxy is running"
} else {
    Write-Warn "Service started but listeners not seen yet. Check logs in $(Join-Path $InstallDir 'logs')"
}

Write-Host ""
Write-Host "    SOCKS: 0.0.0.0:$socks"
Write-Host "    HTTP:  0.0.0.0:$http"
Write-Host "    RADIUS: $(if ($resp.radius_server) { $resp.radius_server } else { '10.147.17.33' })"
Write-Host "    Logs:   $(Join-Path $InstallDir 'logs\proxy.log')"
Write-Host ""
Write-Host "Keep this PC plugged in and awake. Sign-out is fine; shutdown/sleep is not."
Write-Host ""
