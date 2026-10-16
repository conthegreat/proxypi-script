# POST resource heartbeat to London over ZeroTier. Safe to run as SYSTEM.
$ErrorActionPreference = "SilentlyContinue"
$InstallDir = if ($env:PROXYPI_INSTALL_DIR) { $env:PROXYPI_INSTALL_DIR } else { Join-Path $env:ProgramData "ProxyPi" }
$envFile = Join-Path $InstallDir "proxy.env"
$nodeFile = Join-Path $InstallDir "node-info.env"
if (-not (Test-Path $envFile)) { exit 0 }

Get-Content -Path $envFile -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) { return }
    $i = $line.IndexOf("=")
    if ($i -lt 1) { return }
    $name = $line.Substring(0, $i).Trim()
    $val = $line.Substring($i + 1).Trim()
    Set-Item -Path "Env:$name" -Value $val
}

if (-not $env:HEARTBEAT_URL -or -not $env:HEARTBEAT_TOKEN) { exit 0 }

$hostname = $env:COMPUTERNAME
$ztNodeId = $null
$ztIp = $null
if (Test-Path $nodeFile) {
    Get-Content $nodeFile | ForEach-Object {
        if ($_ -match '^ZT_NODE_ID=(.+)$') { $ztNodeId = $Matches[1].Trim() }
        if ($_ -match '^ZEROTIER_NODE_ID=(.+)$' -and -not $ztNodeId) { $ztNodeId = $Matches[1].Trim() }
        if ($_ -match '^ZT_IP=(.+)$') { $ztIp = $Matches[1].Trim() }
        if ($_ -match '^HOSTNAME=(.+)$') { $hostname = $Matches[1].Trim() }
    }
}
if ($ztIp -eq "pending") { $ztIp = $null }
if (-not $ztIp) {
    $addr = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "10.147.*" } | Select-Object -First 1
    if ($addr) { $ztIp = $addr.IPAddress }
}

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
$memTotal = [int]([double]$os.TotalVisibleMemorySize / 1024)
$memAvail = [int]([double]$os.FreePhysicalMemory / 1024)
$memPct = $null
if ($memTotal -gt 0) { $memPct = [math]::Round((($memTotal - $memAvail) * 100.0) / $memTotal, 1) }
$uptime = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$diskPct = $null
if ($disk -and $disk.Size -gt 0) {
    $diskPct = [int][math]::Round((($disk.Size - $disk.FreeSpace) * 100.0) / $disk.Size, 0)
}

$svc = Get-Service -Name "ProxyPi" -ErrorAction SilentlyContinue
$proxyActive = [bool]($svc -and $svc.Status -eq "Running")
if (-not $proxyActive) {
    $task = Get-ScheduledTask -TaskName "ProxyPiProxy" -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq "Running") { $proxyActive = $true }
}

$socksListening = $false
if ($env:SOCKS_PORT) {
    $socksListening = [bool](Get-NetTCPConnection -State Listen -LocalPort ([int]$env:SOCKS_PORT) -ErrorAction SilentlyContinue)
}

$body = @{
    hostname        = $hostname
    zt_node_id      = $ztNodeId
    zt_ip           = $ztIp
    cpu_pct         = $(if ($cpu) { [math]::Round($cpu.Average, 1) } else { $null })
    mem_total_mb    = $memTotal
    mem_avail_mb    = $memAvail
    mem_pct         = $memPct
    temp_c          = $null
    disk_pct        = $diskPct
    load1           = $null
    conntrack       = $null
    proxy_active    = $proxyActive
    socks_listening = $socksListening
    uptime_sec      = $uptime
} | ConvertTo-Json -Compress

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-RestMethod -Method POST -Uri $env:HEARTBEAT_URL -Headers @{
    Authorization = "Bearer $($env:HEARTBEAT_TOKEN)"
    Accept        = "application/json"
} -ContentType "application/json" -Body $body -TimeoutSec 20 | Out-Null
