# init_sqlite.ps1 (modulunabhängig)
param (
    [string]$DbPath = "C:\Scripts\logon_failures.sqlite",
    [string]$DllPath = "C:\Scripts\sqlite\System.Data.SQLite.dll"
)

# DLL laden
if (!(Test-Path $DllPath)) {
    Write-Error "SQLite-DLL nicht gefunden unter: $DllPath"
    exit 1
}
Add-Type -Path $DllPath

# Prüfen, ob DB existiert
if (!(Test-Path $DbPath)) {
    Write-Output "Erstelle SQLite-Datenbank unter: $DbPath"

    # Verbindung erstellen
    $connectionString = "Data Source=$DbPath;Version=3;"
    $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
    $connection.Open()

    # Tabelle anlegen
    $command = $connection.CreateCommand()
    $command.CommandText = @"
CREATE TABLE IF NOT EXISTS failed_logins (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_time TEXT,
    username TEXT,
    domain TEXT,
    workstation TEXT,
    ip_address TEXT,
    logon_type INTEGER,
    logon_type_desc TEXT,
    event_id INTEGER,
    UNIQUE(event_time, username, workstation, logon_type)
);
"@
    $command.ExecuteNonQuery()
    $connection.Close()

    Write-Output "Tabelle 'failed_logins' erstellt."
} else {
    Write-Output "Datenbank existiert bereits unter: $DbPath"
}
