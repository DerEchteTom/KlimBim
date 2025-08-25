<#
.SYNOPSIS
  Importiert Event ID 4625 aus dem Security-Log direkt in eine SQLite-Datenbank.
.DESCRIPTION
  - Pfade & Konfiguration über zentrale Getter aus Config-Helper.ps1
  - DNS-Auflösung mit Cache für SourceNetworkAddress
  - NTSTATUS-Code-Mapping für FailureReason
  - Insert in Tabelle FailedLogons via sqlite3.exe
#>

. "$PSScriptRoot\..\Config-Helper.ps1"

# 1) Pfade laden
$sqliteExe = Get-SqliteExePath
$dbFile    = Get-DatabasePath

# 2) Validierung / Datenbank ggf. erstellen
if (-not (Test-Path $dbFile)) {
    New-Item -Path $dbFile -ItemType File -Force | Out-Null
    Write-Host "Neue Datenbank-Datei erstellt: $dbFile"
}

# 3) Tabellen-Schema vorbereiten
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

# 4) NTSTATUS Mapping
$failureReasons = @{
    '0xC000006D' = 'unknown user name or bad password'
    '0xC000006A' = 'user name correct but bad password'
    '0xC0000234' = 'account locked out'
    '0xC000006E' = 'user logon restriction'
    '0xC0000070' = 'account restriction at this computer'
    '0xC0000071' = 'password expired'
    '0xC000015B' = 'account currently disabled'
}

# 5) DNS Cache
$dnsCache = @{}

# 6) Events abrufen
$events = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625 } -MaxEvents 500

# 7) SQL-Batch erstellen
$batch = @()
$batch += "BEGIN TRANSACTION;"
$batch += $tableSql

foreach ($e in $events) {
    $xml = [xml]$e.ToXml()
    $d   = @{}
    foreach ($n in $xml.Event.EventData.Data) {
        $d[$n.Name] = $n.'#text'
    }

    $ip = $d['IpAddress']
    $resolvedHost = ''
    if ($ip -and $ip -ne '-' -and $ip -ne '::1') {
        if (-not $dnsCache.ContainsKey($ip)) {
            try { $dnsCache[$ip] = [System.Net.Dns]::GetHostEntry($ip).HostName }
            catch { $dnsCache[$ip] = '' }
        }
        $resolvedHost = $dnsCache[$ip]
    }

    $status    = $d['Status']
    $subStatus = $d['SubStatus']
    $reason    = if ($failureReasons.ContainsKey($status)) { $failureReasons[$status] } else { "unknown status code" }

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
        "'$($reason                 -replace "'","''")'",
        "'$($d['WorkstationName']   -replace "'","''")'",
        "'$ip'",
        [int]($d['IpPort']          -as [int]),
        [int]($d['ProcessId']       -as [int]),
        "'$($d['ProcessName']       -replace "'","''")'",
        "'$($d['LogonProcessName']  -replace "'","''")'",
        "'$($d['AuthenticationPackageName'] -replace "'","''")'",
        "'$($d['TransitedServices'] -replace "'","''")'",
        "'$($d['PackageName']       -replace "'","''")'",
        [int]($d['KeyLength']       -as [int]),
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
$batch | & $sqliteExe $dbFile

Write-Host "Events erfolgreich in SQLite gespeichert: $dbFile"