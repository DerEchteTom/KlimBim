<#
  Recreate-InstallMonitorDB.ps1
  - Bestehende installations.db umbenennen
  - Neue installations.db mit Schema anlegen
  Stand: 2025-07-24
#>

# 1) Pfade setzen
$baseDir  = $PSScriptRoot
$dataDir  = Join-Path $baseDir 'data'
$dbName   = 'installations.db'
$dbPath   = Join-Path $dataDir $dbName

# 2) data-Verzeichnis anlegen, falls es fehlt
if (-not (Test-Path $dataDir)) {
    New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    Write-Host "Angelegt: $dataDir"
}

# 3) Vorhandene Datenbank umbenennen
if (Test-Path $dbPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupName = "installations_$timestamp.db"
    $backupPath = Join-Path $dataDir $backupName

    Rename-Item -Path $dbPath -NewName $backupName -Force
    Write-Host "Vorhandene DB umbenannt in:`n  $backupName"
}
else {
    Write-Host "Keine bestehende DB gefunden, es wird direkt neu angelegt."
}

# 4) PSSQLite-Modul sicherstellen
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Write-Host "Installiere PSSQLite..."
    Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
}

Import-Module PSSQLite -ErrorAction Stop

# 5) Neue SQLite-Datenbank anlegen
Write-Host "Erstelle neue Datenbank..."
New-SqliteDatabase -DataSource $dbPath

# 6) Tabellen und Metadata anlegen
Invoke-SqliteQuery -DataSource $dbPath -Query @'
CREATE TABLE Installations (
    DisplayName TEXT,
    InstallDate TEXT,
    TimeLogged  TEXT,
    Exported    INTEGER DEFAULT 0
);
CREATE TABLE Metadata (
    Key   TEXT PRIMARY KEY,
    Value TEXT
);
INSERT INTO Metadata(Key,Value) VALUES('LastRun','1970-01-01 00:00:00');
INSERT INTO Metadata(Key,Value) VALUES('LastExport','1970-01-01 00:00:00');
'@

Write-Host "Neue Datenbank erstellt unter:`n  $dbPath" -ForegroundColor Green