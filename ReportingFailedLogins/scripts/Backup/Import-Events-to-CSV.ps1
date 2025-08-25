# Import-Events-to-SQLite.ps1

# 1) Config einlesen
$config = Get-Content './config.json' | ConvertFrom-Json
$sqliteExe = $config.sqlite3Path
$dbFile    = $config.databaseFile

# 2) Tabelle anlegen (bei erstem Durchlauf)
$tableSql = @"
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
"@
& $sqliteExe $dbFile ".timeout 5000" ".exit"       |
    Out-Null
& $sqliteExe $dbFile $tableSql

# 3) DNS-Cache initialisieren und Mappings laden
$dnsCache = @{}
$failureReasons = @{
    '0xC000006D' = 'unknown user name or bad password'
    '0xC000006A' = 'user name correct but bad password'
    '0xC0000234' = 'account locked out'
    '0xC000006E' = 'user logon restriction'
    '0xC0000070' = 'account restriction at this computer'
    '0xC0000071' = 'password expired'
    '0xC000015B' = 'account currently disabled'
}

# 4) Events auslesen
$events = Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625 } -MaxEvents 500

foreach ($e in $events) {
    $xml = [xml]$e.ToXml()
    $d   = @{ }
    foreach ($node in $xml.Event.EventData.Data) {
        $d[$node.Name] = $node.'#text'
    }

    # DNS Lookup mit Cache
    $ip = $d['IpAddress']
    if ($ip -and $ip -ne '-' -and $ip -ne '::1') {
        if ($dnsCache.ContainsKey($ip)) {
            $host = $dnsCache[$ip]
        } else {
            try { $host = [Net.Dns]::GetHostEntry($ip).HostName } catch { $host = '' }
            $dnsCache[$ip] = $host
        }
    } else {
        $host = ''
    }

    # Fehlermapping
    $reason = $failureReasons[$d['Status']] 
    if (-not $reason) { $reason = 'unknown status code' }

    # INSERT-Statement zusammenbauen
    $cols = @(
        'EventID','TimeCreated','SubjectUserSid','SubjectUserName','SubjectDomainName',
        'SubjectLogonId','LogonType','TargetUserSid','TargetUserName','TargetDomainName',
        'Status','SubStatus','FailureReason','WorkstationName','IpAddress','IpPort',
        'ProcessId','ProcessName','LogonProcessName','AuthenticationPackageName',
        'TransitedServices','PackageName','KeyLength','ResolvedHost'
    )
    $vals = @(
        4625,
        $e.TimeCreated.ToString('o'),
        $d['SubjectUserSid'],
        $d['SubjectUserName'],
        $d['SubjectDomainName'],
        $d['SubjectLogonId'],
        [int]$d['LogonType'],
        $d['TargetUserSid'],
        $d['TargetUserName'],
        $d['TargetDomainName'],
        $d['Status'],
        $d['SubStatus'],
        $reason,
        $d['WorkstationName'],
        $ip,
        [int]$d['IpPort'],
        [int]$d['ProcessId'],
        $d['ProcessName'],
        $d['LogonProcessName'],
        $d['AuthenticationPackageName'],
        $d['TransitedServices'],
        $d['PackageName'],
        [int]$d['KeyLength'],
        $host
    ) | ForEach-Object {
        if ($_ -is [int]) { $_ } else { "'$($_ -replace "'","''")'" }
    }

    $sql = "INSERT INTO FailedLogons (" + ($cols -join ',') + ") VALUES (" + ($vals -join ',') + ");"
    & $sqliteExe $dbFile $sql | Out-Null
}

Write-Host "Alle Events in SQLite-Datenbank gespeichert: $dbFile"