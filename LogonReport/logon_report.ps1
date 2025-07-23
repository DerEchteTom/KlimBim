# logon_report.ps1
Import-Module DbSQLite

# Konfiguration laden
$configPath = ".\config.json"
if (!(Test-Path $configPath)) {
    Write-Error "Konfigurationsdatei $configPath nicht gefunden."
    exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$dbPath = $config.db_path
$lookback = (Get-Date).AddDays(-$config.eventlog_lookback_days)

# Tabelle vorbereiten (falls noch nicht da)
$sqlInit = @"
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
Invoke-SQLiteQuery -DataSource $dbPath -Query $sqlInit

# LogonType-Übersetzung
$logonTypes = @{
    2 = "Interactive"
    3 = "Network"
    4 = "Batch"
    5 = "Service"
    7 = "Unlock"
    10 = "RemoteInteractive"
    11 = "CachedInteractive"
}

# Events holen
$filter = @{ LogName='Security'; Id=4625; StartTime=$lookback }
$events = Get-WinEvent -FilterHashtable $filter

$data = @()

foreach ($event in $events) {
    $xml = [xml]$event.ToXml()
    $fields = $xml.Event.EventData.Data

    $record = [PSCustomObject]@{
        event_time     = $event.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
        username       = ($fields | Where-Object {$_.Name -eq "TargetUserName"}).'#text'
        domain         = ($fields | Where-Object {$_.Name -eq "TargetDomainName"}).'#text'
        workstation    = ($fields | Where-Object {$_.Name -eq "WorkstationName"}).'#text'
        ip_address     = ($fields | Where-Object {$_.Name -eq "IpAddress"}).'#text'
        logon_type     = ($fields | Where-Object {$_.Name -eq "LogonType"}).'#text'
        logon_type_desc = ""
        event_id       = 4625
    }

    if ($record.username -and $record.logon_type) {
        $record.logon_type_desc = $logonTypes[$record.logon_type]  # Textbeschreibung

        # In DB schreiben, wenn neu
        $insert = @"
INSERT OR IGNORE INTO failed_logins
(event_time, username, domain, workstation, ip_address, logon_type, logon_type_desc, event_id)
VALUES (
'$($record.event_time)',
'$($record.username)',
'$($record.domain)',
'$($record.workstation)',
'$($record.ip_address)',
$($record.logon_type),
'$($record.logon_type_desc)',
$($record.event_id)
);
"@
        Invoke-SQLiteQuery -DataSource $dbPath -Query $insert
        $data += $record
    }
}

# HTML-Tabelle
$htmlRows = $data | Sort-Object event_time | ForEach-Object {
    "<tr><td>$($_.event_time)</td><td>$($_.username)</td><td>$($_.workstation)</td><td>$($_.ip_address)</td><td>$($_.logon_type_desc)</td></tr>"
}

$htmlBody = @"
<html>
<head><style>
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid black; padding: 5px; }
</style></head>
<body>
<h2>Fehlgeschlagene Anmeldungen (seit $($lookback.ToString("yyyy-MM-dd")))</h2>
<table>
<tr><th>Zeit</th><th>Benutzer</th><th>Computer</th><th>IP-Adresse</th><th>Typ</th></tr>
$htmlRows
</table>
</body>
</html>
"@

# E-Mail versenden
Send-MailMessage -SmtpServer $config.smtp_server `
    -Port $config.smtp_port `
    -From $config.mail_from `
    -To $config.mail_to `
    -Subject $config.report_subject `
    -Body $htmlBody `
    -BodyAsHtml
