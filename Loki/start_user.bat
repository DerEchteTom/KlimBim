@echo off
setlocal ENABLEEXTENSIONS
cd /d "%~dp0"

echo ================================
echo   Welche Version moechtest du?
echo ================================
echo [1] Parse-LokiInteractive_V1.ps1
echo [2] Parse-LokiInteractive_V2.ps1
echo [3] Beide nacheinander
echo [X] Abbrechen
echo.

choice /C 123X /N /M "Bitte Auswahl eingeben: "
set "opt=%ERRORLEVEL%"

if "%opt%"=="4" (
    echo Abgebrochen.
    goto :eof
)

if "%opt%"=="1" (
    set "SCRIPT=Parse-LokiInteractive_V1.ps1"
    call :runps "%SCRIPT%"
    goto :eof
)

if "%opt%"=="2" (
    set "SCRIPT=Parse-LokiInteractive_V2.ps1"
    call :runps "%SCRIPT%"
    goto :eof
)

if "%opt%"=="3" (
    call :runps "Parse-LokiInteractive_V1.ps1"
    call :runps "Parse-LokiInteractive_V2.ps1"
    goto :eof
)

goto :eof

:: ---------- Unterprogramm zum Ausführen ----------
:runps
set "PS1=%~dp0%~1"
if not exist "%PS1%" (
    echo PowerShell-Skript nicht gefunden: "%PS1%"
    pause
    goto :eof
)
echo Starte %~1 ...
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "%PS1%" %*
echo.

goto :eof