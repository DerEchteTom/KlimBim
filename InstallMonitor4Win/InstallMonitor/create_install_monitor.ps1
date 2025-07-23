# Projektverzeichnis
$basePath = "I:\GitHub\InstallMonitor4Win"
$dataPath = Join-Path $basePath "data"
$dbFile   = Join-Path $dataPath "installations.db"
$guiFile  = Join-Path $basePath "InstallMonitor_GUI.ps1"

# Verzeichnisse erstellen
New-Item -Path $dataPath -ItemType Directory -Force | Out-Null

# SQLite-Modul sicherstellen
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module PSSQLite -ErrorAction Stop

# Datenbank neu erstellen
if (Test-Path $dbFile) { Remove-Item $dbFile -Force }
New-SqliteDatabase -DataSource $dbFile

# Tabellenstruktur anlegen
Invoke-SqliteQuery -DataSource $dbFile -Query @'
CREATE TABLE Installations (
    DisplayName TEXT,
    InstallDate TEXT,
    TimeLogged  TEXT
);
CREATE TABLE Metadata (
    Key   TEXT PRIMARY KEY,
    Value TEXT
);
INSERT INTO Metadata(Key,Value) VALUES('LastRun','1970-01-01 00:00:00');
'@

# GUI-Skript erzeugen
@'
<GUI-Skript wird hier eingefügt>
'@ | Set-Content -Encoding UTF8 -Path $guiFile

# Verknüpfung auf Desktop (optional)
$lnk = "$env:USERPROFILE\Desktop\InstallMonitor GUI.lnk"
$ws  = New-Object -ComObject WScript.Shell
$shl = $ws.CreateShortcut($lnk)
$shl.TargetPath = "powershell.exe"
$shl.Arguments  = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guiFile`""
$shl.IconLocation = "powershell.exe"
$shl.Save()

Write-Host "✅ InstallMonitor-Projekt wurde eingerichtet unter:`n$basePath" -ForegroundColor Green