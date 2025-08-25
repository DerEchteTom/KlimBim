<#
    Import-Events-to-SQLite.ps1
    - Reads failed logons (Event ID 4625) from Security log
    - Loads sqlite3.exe path and database file from config.json
    - Resolves source IP via DNS with in-memory cache
    - Maps NTSTATUS codes to English failure reasons
    - Persists ALL relevant 4625 fields into a SQLite table in one batch
#>

# 1) Helpers laden (Path.ps1 + Config-Helper.ps1)
$sd = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sd "..\Path.ps1") -CallerScriptPath $MyInvocation.MyCommand.Path
. (Join-Path $sd "..\Config-Helper.ps1")

# 2) Config einlesen
$config = Load-Config

# 3) Pfade ermitteln
$projectRoot = Get-ProjectRoot
$sqliteExe   = Join-Path $projectRoot $config.SqliteExe
$dbFile      = Join-Path $projectRoot $config.DatabaseFile

# 4) Validierung
if (-not (Test-Path $sqliteExe)) {
    throw "sqlite3.exe not found at path: $sqliteExe"
}
if (-not (Test-Path $dbFile)) {
    # Neue Datenbankdatei anlegen, falls noch nicht existent
    New-Item -Path $dbFile -ItemType File -Force | Out-Null
}

# 5) Tabellen-Schema (CREATE TABLE IF NOT EXISTS …)
$tableSql = @'
CREATE TABLE IF NOT EXISTS FailedLogons (
    Id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    EventID                   INTEGER,
    TimeStamp                 TEXT,
    SubjectUserSid            TEXT,
    SubjectUserName           TEXT,
    SubjectDomainName         TEXT,
    SubjectLogonId            TEXT,
    LogonType                 INTEGER,
    TargetUserSid             TEXT,
    TargetUserName            TEXT,
    TargetDomainName          TEXT,
    StatusCode                TEXT,
    SubStatusCode             TEXT,
    FailureReason             TEXT,
    WorkstationName           TEXT,
    SourceNetworkAddress      TEXT,
    SourcePort                INTEGER,
    ProcessId                 INTEGER,
    ProcessName               TEXT,
    LogonProcessName          TEXT,
    AuthenticationPackageName TEXT,
    TransitedServices         TEXT,
    PackageName               TEXT,
    KeyLength                 INTEGER,
    ResolvedHost              TEXT
);
'@

# 6) Status-Code → English mapping
$failureReasons = @{
    '0xC000006D' = 'unknown user name or bad password'
    '0xC000006A' = 'user name correct but bad password'
    '0xC0000234' = 'account locked out'
    '0xC000006E' = 'user logon restriction'
    '0xC0000070' = 'account restriction at this computer'
    '0xC0000071' = 'password expired'
    '0xC000015B' = 'account currently disabled'
}

# 7) DNS-Cache initialisieren
$dnsCache = @{}

# 8) Events abrufen
$events = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625 } -MaxEvents 500

# 9) SQL-Batch zusammenstellen
$batch = @()
$batch += "BEGIN TRANSACTION;"
$batch += $tableSql

foreach ($e in $events) {
    # a) Alle Data-Felder in ein Dictionary packen
    $xml = [xml]$e.ToXml()
    $d   = @{}
    foreach ($n in $xml.Event.EventData.Data) {
        $d[$n.Name] = $n.'#text'
    }

    # b) DNS-Lookup mit Cache
    $ip = $d['IpAddress']
    if ($ip -and $ip -ne '-' -and $ip -ne '::1') {
        if (-not $dnsCache.ContainsKey($ip)) {
            try { $dnsCache[$ip] = [System.Net.Dns]::GetHostEntry($ip).HostName }
            catch { $dnsCache[$ip] = '' }
        }
        $resolvedHost = $dnsCache[$ip]
    } else {
        $resolvedHost = ''
    }

    # c) Fehlermeldung mappen
    $status    = $d['Status']
    $subStatus = $d['SubStatus']
    $reason    = if ($failureReasons.ContainsKey($status)) { $failureReasons[$status] } else { "unknown status code" }

    # d) Feldwerte vorbereiten
    $cols = @(
        4625,
        "'$($e.TimeCreated.ToString('o'))'",
        "'$($d['SubjectUserSid']    -replace "'","''")'",
        "'$($d['SubjectUserName']   -replace "'","''")'",
        "'$($d['SubjectDomainName'] -replace "'","''")'",
        "'$($d['SubjectLogonId']    -replace "'","''")'",
        [int]$d['LogonType'],
        "'$($d['TargetUserSid']     -replace "'","''")'",
        "'$($d['TargetUserName']    -replace "'","''")'",
        "'$($d['TargetDomainName']  -replace "'","''")'",
        "'$status'",
        "'$subStatus'",
        "'$($reason                -replace "'","''")'",
        "'$($d['WorkstationName']   -replace "'","''")'",
        "'$ip'",
        [int]($d['IpPort']          -as [int]   ),
        [int]($d['ProcessId']       -as [int]   ),
        "'$($d['ProcessName']       -replace "'","''")'",
        "'$($d['LogonProcessName']  -replace "'","''")'",
        "'$($d['AuthenticationPackageName'] -replace "'","''")'",
        "'$($d['TransitedServices'] -replace "'","''")'",
        "'$($d['PackageName']       -replace "'","''")'",
        [int]($d['KeyLength']       -as [int]   ),
        "'$($resolvedHost           -replace "'","''")'"
    )

    $batch += "INSERT INTO FailedLogons (
        EventID,TimeStamp,SubjectUserSid,SubjectUserName,SubjectDomainName,SubjectLogonId,
        LogonType,TargetUserSid,TargetUserName,TargetDomainName,
        StatusCode,SubStatusCode,FailureReason,
        WorkstationName,SourceNetworkAddress,SourcePort,
        ProcessId,ProcessName,LogonProcessName,AuthenticationPackageName,
        TransitedServices,PackageName,KeyLength,ResolvedHost
    ) VALUES (" + ($cols -join ',') + ");"
}

$batch += "COMMIT;"

# 10) Batch an sqlite3.exe übergeben
$batch | & $sqliteExe $dbFile

Write-Host "All events written to SQLite DB at $dbFile"