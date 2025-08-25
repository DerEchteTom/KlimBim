@echo off
REM Starte PowerShell-Skript mit Administratorrechten, relativ zum Batch-Pfad

setlocal

REM Ermittle den absolute Pfad des Skriptverzeichnisses
set "scriptDir=%~dp0"
set "psScript=%scriptDir%UpdateScript.ps1"

REM Pruefe ob Pfad ein UNC-Pfad ist
echo %scriptDir% | find "\\" >nul
if %errorlevel%==0 (
    echo Das Skript kann nicht von einem Netzlaufwerk oder UNC-Pfad ausgefuehrt werden.
    echo Bitte kopiere es auf ein lokales Laufwerk.
    pause
    exit /b
)

REM Starte PowerShell mit Adminrechten und uebergebe das Skript
powershell -Command "Start-Process PowerShell -ArgumentList '-ExecutionPolicy Bypass -File \"%psScript%\"' -Verb RunAs"

endlocal