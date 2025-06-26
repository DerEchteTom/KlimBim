@echo off
set "DB=I:\GitHub\InstallMonitor4Win\InstallMonitor\data\installations.db"
set "APPNAME=TestApp123"

I:\GitHub\InstallMonitor4Win\InstallMonitor\sqlite3.exe "%DB%" "DELETE FROM Installations WHERE DisplayName = '%APPNAME%';"
echo Fake installation '%APPNAME%' entfernt.
pause