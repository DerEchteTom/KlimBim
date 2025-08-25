# Konfigurationsfunktionen laden
. "$PSScriptRoot\..\Config-Helper.ps1"

# Konfiguration abrufen
# $sqliteExe     = Get-SqliteExePath
# $dbFile        = Get-DatabasePath
# $excludedUsers = Get-ExcludedUsers
$reportDir     = Get-ReportDirPath

# Standardwerte
$TopN       = 25
$To         = "thomas.schmidt@technoteam.de"
$From       = "noreply@technoteam.de"
$SmtpServer = "172.16.30.21"
$SubjectTemplate = "IT-Report Top {0} user failed logons - {1:yyyy-MM-dd}"

# Letztes HTML-File im Report-Verzeichnis finden
$HtmlReportPath = Get-ChildItem -Path $reportDir -Filter *.html |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Select-Object -ExpandProperty FullName

if (-not $HtmlReportPath) {
    Throw "Kein HTML-Report im Verzeichnis gefunden: $reportDir"
}

# Prüfen, ob Datei älter als heute
$reportDate = (Get-Item $HtmlReportPath).LastWriteTime.Date
$today      = (Get-Date).Date
$isOutdated = $reportDate -lt $today

# HTML-Datei als Text laden
$htmlRaw = Get-Content -Path $HtmlReportPath -Raw

# Tabelle extrahieren (nur tbody)
$tbodyMatch = [regex]::Match($htmlRaw, "<tbody>(.*?)</tbody>", "Singleline")
if (-not $tbodyMatch.Success) {
    Throw "Keine <tbody> im HTML gefunden: $HtmlReportPath"
}

$tbody = $tbodyMatch.Groups[1].Value

# Zeilen extrahieren
$rowMatches = [regex]::Matches($tbody, "<tr>(.*?)</tr>", "Singleline")
$entries = @()

foreach ($row in $rowMatches) {
    $rowHtml = $row.Groups[1].Value
    $cellMatches = [regex]::Matches($rowHtml, "<td.*?>(.*?)</td>", "Singleline")
    $cells = $cellMatches | ForEach-Object { $_.Groups[1].Value.Trim() }

    # Spaltenpositionen herausfinden (nur beim ersten Durchlauf)
    if (-not $columnMap) {
        $headerMatch = [regex]::Match($htmlRaw, "<thead>.*?<tr>(.*?)</tr>", "Singleline")
        $headerHtml = $headerMatch.Groups[1].Value
        $headerCells = [regex]::Matches($headerHtml, "<th.*?>(.*?)</th>", "Singleline") |
            ForEach-Object { $_.Groups[1].Value.Trim() }

        $columnMap = @{
            User  = ($headerCells.IndexOf("Benutzer"))
            Count = ($headerCells.IndexOf("Ereignis-Count"))
        }

        if ($columnMap.User -lt 0 -or $columnMap.Count -lt 0) {
            Throw "Spalten 'Benutzer' oder 'Ereignis-Count' nicht gefunden im Header."
        }
    }

    $user  = $cells[$columnMap.User]
    $count = [int]$cells[$columnMap.Count]

    $entries += [pscustomobject]@{
        User  = $user
        Count = $count
    }
}

# Top-N auswählen
$topList = $entries |
    Sort-Object -Property Count -Descending |
    Select-Object -First $TopN

# Betreff erzeugen
$Subject = [string]::Format($SubjectTemplate, $TopN, (Get-Date))

# Warnung bei veraltetem Report
$warningText = ""
if ($isOutdated) {
    $warningText = "<p style='color:red'><strong>⚠ Achtung:</strong> Der Report ist aelter als das aktuelle Datum ($($reportDate.ToShortDateString()))</p>"
}

# HTML-Body erzeugen
$bodyFragment = $topList |
    ConvertTo-Html -Fragment -As Table `
        -PreContent "<h2>Top $TopN user failed logons</h2>"

$HtmlBody = @"
<html>
  <body>
    $warningText
    $bodyFragment
    <p>Details im vollständigen Report: <br><code>$HtmlReportPath</code></p>
  </body>
</html>
"@

# E-Mail versenden
Send-MailMessage `
    -To $To `
    -From $From `
    -Subject $Subject `
    -Body $HtmlBody `
    -BodyAsHtml `
    -SmtpServer $SmtpServer

Write-Host "E-Mail erfolgreich gesendet an $To"
if ($isOutdated) {
    Write-Host "Hinweis: Der verwendete Report ist veraltet (vom $reportDate)"
}