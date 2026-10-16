@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo Run this file as Administrator.
  echo Right-click activate.cmd -^> Run as administrator
  echo.
  pause
  exit /b 1
)
echo Paste the activation token from the ProxyPi email, then press Enter.
set /p TOKEN=Token:
if "%TOKEN%"=="" (
  echo No token entered.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$env:ACTIVATION_TOKEN='%TOKEN%'; $env:ACTIVATION_API_URL='https://proxypi.co.uk'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/activate.ps1 | iex"
echo.
pause
