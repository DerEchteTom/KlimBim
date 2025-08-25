param(
    [switch]$ForceReset
)

. "$PSScriptRoot\helper.ps1"

$dbFile    = $Global:InstallDbPath
$backupDir = Join-Path $PSScriptRoot 'backup'

# Backup and optional reset
if (Test-Path $dbFile) {
    if (-not (Test-Path $backupDir)) {
        New-Item $backupDir -ItemType Directory | Out-Null
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupFile = Join-Path $backupDir "installations_$ts.db"
    Copy-Item $dbFile $backupFile
    Write-Host "Backup created: $backupFile"

    if ($ForceReset) {
        Remove-Item $dbFile -Force
        Write-Host "Existing database removed due to -ForceReset"
    }
}

# Schema definition
$sql = @"
CREATE TABLE IF NOT EXISTS Snapshots (
  SnapshotID INTEGER PRIMARY KEY AUTOINCREMENT,
  CreatedAt  TEXT    NOT NULL,
  Note       TEXT,
  AppCount   INTEGER,
  ScanHash   TEXT,
  IsInitial  INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS SnapshotApps (
  SnapshotID   INTEGER NOT NULL,
  StableKey    TEXT    NOT NULL,
  UniqueKey    TEXT,
  DisplayName  TEXT    NOT NULL,
  Version      TEXT    NOT NULL,
  Publisher    TEXT,
  Source       TEXT,
  InstallDate  TEXT,
  PRIMARY KEY (SnapshotID, StableKey),
  FOREIGN KEY (SnapshotID) REFERENCES Snapshots(SnapshotID)
);

CREATE TABLE IF NOT EXISTS SnapshotMeta (
  MetaID         INTEGER PRIMARY KEY AUTOINCREMENT,
  RotationPolicy TEXT    NOT NULL,
  MaxSnapshots   INTEGER NOT NULL,
  LastRotation   TEXT
);

CREATE TABLE IF NOT EXISTS SnapshotLog (
  LogID      INTEGER PRIMARY KEY AUTOINCREMENT,
  SnapshotID INTEGER NOT NULL,
  Action     TEXT    NOT NULL,
  Timestamp  TEXT    NOT NULL,
  FOREIGN KEY (SnapshotID) REFERENCES Snapshots(SnapshotID)
);
"@

Invoke-SqliteCli -DbFile $dbFile -Sql $sql -Silent
Write-Host "Database initialized or upgraded: $dbFile"