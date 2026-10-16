# Loads proxy.env then starts proxyscript.py. Used by the ProxyPi Windows service.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$envFile = Join-Path $root "proxy.env"
$py = Join-Path $root "venv\Scripts\python.exe"
$script = Join-Path $root "proxyscript.py"
if (-not (Test-Path $envFile)) { throw "Missing $envFile — run activate first." }
if (-not (Test-Path $py)) { throw "Missing $py — re-run join." }
if (-not (Test-Path $script)) { throw "Missing $script — re-run join." }

Get-Content -Path $envFile -Encoding UTF8 | ForEach-Object {
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

Set-Location $root
$env:PYTHONUNBUFFERED = "1"
& $py $script
exit $LASTEXITCODE
