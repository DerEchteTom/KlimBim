@echo off
REM Neustart als Admin, falls nötig
net session >nul 2>&1 || (
  echo [INFO] Neustart als Administrator...
  powershell -Command "Start-Process '%~f0' -Verb runAs"
  exit /b
)

powershell -ExecutionPolicy Bypass -File "%~dp0InstallMonitor_GUI.ps1"
pause
