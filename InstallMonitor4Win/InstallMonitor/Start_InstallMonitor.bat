@echo off
REM Neustart als Admin, falls nötig
net session >nul 2>&1 || (
  echo [INFO] Neustart als Administrator...
  powershell -Command "Start-Process '%~f0' -Verb runAs"
  exit /b
)

REM InstallMonitor.ps1 mit SendMail aufrufen
powershell -ExecutionPolicy Bypass -File "%~dp0InstallMonitor.ps1" -SendMail
