# Shared helpers for ProxyPi Windows join / activate.
$ErrorActionPreference = "Stop"

function Use-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Write-Info([string]$Message) { Write-Host "[*] $Message" }
function Write-Ok([string]$Message) { Write-Host "[+] $Message" }
function Write-Warn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Die([string]$Message) {
    Write-Host "[-] $Message" -ForegroundColor Red
    exit 1
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        Write-Die "Open PowerShell as Administrator and run this again (right-click PowerShell -> Run as administrator)."
    }
}

function Require-Windows64 {
    if ($env:OS -ne "Windows_NT") { Write-Die "This installer is for Windows 10/11 only." }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Die "64-bit Windows is required."
    }
}

function Get-RepoRaw {
    if ($env:PROXYPI_REPO_URL) { return $env:PROXYPI_REPO_URL.TrimEnd("/") }
    return "https://raw.githubusercontent.com/conthegreat/proxypi-script/main"
}

function Get-InstallDir {
    if ($env:PROXYPI_INSTALL_DIR) { return $env:PROXYPI_INSTALL_DIR }
    return Join-Path $env:ProgramData "ProxyPi"
}

function Get-ZeroTierCli {
    $candidates = @(
        (Join-Path $env:ProgramData "ZeroTier\One\zerotier-cli.bat"),
        "${env:ProgramFiles}\ZeroTier\One\zerotier-cli.bat",
        "${env:ProgramFiles(x86)}\ZeroTier\One\zerotier-cli.bat"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command "zerotier-cli" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-ZeroTier {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ZtArgs)
    $cli = Get-ZeroTierCli
    if (-not $cli) { Write-Die "ZeroTier CLI not found. Re-run join after ZeroTier is installed." }
    $out = & $cli @ZtArgs 2>&1
    $code = $LASTEXITCODE
    return @{ Code = $code; Text = ($out | Out-String) }
}

function Get-ZeroTierNodeId {
    $r = Invoke-ZeroTier "info"
    if ($r.Code -ne 0 -and -not $r.Text) { return "" }
    $line = ($r.Text -split "`r?`n" | Where-Object { $_ -match "info" } | Select-Object -First 1)
    if ($line -match '\b([0-9a-fA-F]{10})\b') { return $Matches[1].ToLower() }
    return ""
}

function Get-ZeroTierIp {
    $r = Invoke-ZeroTier "listnetworks"
    $m = [regex]::Match($r.Text, '10\.147\.\d+\.\d+')
    if ($m.Success) { return $m.Value }
    $addr = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "10.147.*" } |
        Select-Object -First 1
    if ($addr) { return $addr.IPAddress }
    return ""
}

function Download-File([string]$Url, [string]$Dest) {
    Use-Tls12
    $dir = Split-Path -Parent $Dest
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    if (-not (Test-Path $Dest) -or (Get-Item $Dest).Length -lt 10) {
        Write-Die "Download failed or empty: $Url"
    }
}

function Import-DotEnv([string]$Path) {
    if (-not (Test-Path $Path)) { Write-Die "Missing $Path" }
    Get-Content -Path $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $i = $line.IndexOf("=")
        if ($i -lt 1) { return }
        $name = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()
        if (($val.StartsWith("'") -and $val.EndsWith("'")) -or ($val.StartsWith('"') -and $val.EndsWith('"'))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        Set-Item -Path "Env:$name" -Value $val
    }
}

function Protect-SecretFile([string]$Path) {
    icacls $Path /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" | Out-Null
}

function Set-NeverSleep {
    Write-Info "Setting this PC to stay awake on power (required for 24/7 proxy)"
    try {
        powercfg /change standby-timeout-ac 0 | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null
        powercfg /change monitor-timeout-ac 0 | Out-Null
        powercfg /change disk-timeout-ac 0 | Out-Null
        powercfg /hibernate off | Out-Null
        powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 | Out-Null
        powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 3 | Out-Null
        powercfg /SETACTIVE SCHEME_CURRENT | Out-Null
    } catch {
        Write-Warn "Could not apply all power settings: $($_.Exception.Message)"
    }
}

function Get-PythonExe {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} "Python312\python.exe"),
        (Join-Path ${env:ProgramFiles} "Python313\python.exe"),
        (Join-Path ${env:LocalAppData} "Programs\Python\Python312\python.exe"),
        (Join-Path ${env:LocalAppData} "Programs\Python\Python313\python.exe")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch "WindowsApps") { return $cmd.Source }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        try {
            $resolved = & $py.Source -3 -c "import sys; print(sys.executable)" 2>$null
            if ($resolved -and (Test-Path $resolved)) { return $resolved.Trim() }
        } catch { }
    }
    return $null
}
