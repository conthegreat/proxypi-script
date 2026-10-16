@echo off
setlocal
net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo Run this file as Administrator.
  echo Right-click join.cmd -^> Run as administrator
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/conthegreat/proxypi-script/main/install/windows/join.ps1 | iex"
echo.
pause
