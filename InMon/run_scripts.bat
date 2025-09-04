@echo off
setlocal
cd /d "%~dp0"

:: Admin? Wenn nein: mit UAC neu starten
>nul 2>&1 net session || (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList 'ELEVATED' -Verb RunAs"
  exit /b
)

if /I "%~1"=="ELEVATED" shift

echo Starte Skripte...
powershell -NoProfile -ExecutionPolicy Bypass -File InitDatabase.ps1 || goto :fail
powershell -NoProfile -ExecutionPolicy Bypass -File SnapshotManager.ps1 || goto :fail
powershell -NoProfile -ExecutionPolicy Bypass -File Generate.ps1 || goto :fail
powershell -NoProfile -ExecutionPolicy Bypass -File GenerateDiff.ps1 || goto :fail
powershell -NoProfile -ExecutionPolicy Bypass -File send.ps1 || goto :fail

echo.
echo Alle Skripte erfolgreich ausgefuehrt.
exit /b 0

:fail
echo.
echo Fehler beim Ausfuehren. Exitcode: %errorlevel%
exit /b %errorlevel%
