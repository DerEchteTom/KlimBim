@echo off
set "DB=I:\GitHub\InstallMonitor4Win\InstallMonitor\data\installations.db"
set "APPNAME=TestApp123"
set "APPDATE=2025-06-29"
for /f %%i in ('powershell -command "Get-Date -Format \"yyyy-MM-dd HH:mm:ss\""') do set "NOW=%%i"

I:\GitHub\InstallMonitor4Win\InstallMonitor\sqlite3.exe "%DB%" "INSERT INTO Installations(DisplayName,InstallDate,TimeLogged) VALUES('%APPNAME%','%APPDATE%','%NOW%');"
echo Fake installation '%APPNAME%' hinzugefügt.
pause