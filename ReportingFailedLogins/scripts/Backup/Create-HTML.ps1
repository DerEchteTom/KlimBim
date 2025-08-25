<# 
.SYNOPSIS 
Generiert einen HTML-Report aus der SQLite-Datenbank basierend auf Fields-Konfiguration, ExcludedUsers und Zeitfilter.

.VERSION 
v1.3 — Bereinigt & stabilisiert

.AUTHOR 
T & Copilot 
#>

# Hilfsfunktionen laden
. "$PSScriptRoot\..\Config-Helper.ps1"

# Konfiguration
$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath
$reportDir     = Get-ReportDirPath
$fields        = Get-FieldsConfig
$excludedUsers = Get-ExcludedUsers

# Zeitfilter
$hoursBack = 24

# Feldliste aus fields.json
$allFieldNames = $fields.PSObject.Properties.Name
if (-not $allFieldNames -contains "TimeStamp") {
    throw "'TimeStamp' muss in fields.json enthalten sein für den Zeitfilter."
}
$columnsList = $allFieldNames -join ", "

# SQL-Query als Einzeiler
$sqlQuery = "SELECT $columnsList FROM FailedLogons WHERE datetime(substr(TimeStamp, 1, 19)) >= datetime('now', '-$hoursBack hours');"

# SQLite-Abfrage
$csvOutput = & $sqliteExe -header -csv $dbFile $sqlQuery
if ($LASTEXITCODE -ne 0) { throw "sqlite3-Abfrage fehlgeschlagen. Exitcode: $LASTEXITCODE" }

# CSV parsen + Userfilter
$data = $csvOutput | ConvertFrom-Csv | Where-Object {
    -not ($excludedUsers -contains $_.SubjectUserName) -and
    -not ($excludedUsers -contains $_.TargetUserName)
}

# Sichtbare Felder + Label-Reihenfolge
$visibleFields = $fields.PSObject.Properties |
    Where-Object { $_.Value.enabled -eq $true } |
    Sort-Object { $_.Value.position }

# Tabellenkopf
$tableHeader = ($visibleFields | ForEach-Object {
    $label = if ($_.Value.label) { $_.Value.label } else { $_.Name }
    "<th>$label</th>"
}) -join "`n"

# Tabellenzeilen
$tableRows = foreach ($row in $data) {
    $cells = foreach ($field in $visibleFields) {
        "<td>$($row[$field.Name])</td>"
    }
    "<tr>`n$($cells -join "`n")`n</tr>"
}

# HTML-Generierung
$timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm"
$reportPath = Join-Path $reportDir "Report_$timestamp.html"
$html = @"
<html>
<head>
    <title>Login Report</title>
    <style>
        body { font-family: Arial; margin: 20px; }
        table { border-collapse: collapse; width: 100%; font-size: 11px; }
        th, td { border: 1px solid #888; padding: 5px; text-align: left; }
        th { background-color: #eeeeee; }
    </style>
</head>
<body>
    <h2>Login Report – letzte $hoursBack Stunden</h2>
    <p>Generiert am: $timestamp</p>
    <table>
        <tr>$tableHeader</tr>
        $tableRows
    </table>
</body>
</html>
"@

# Speichern
$html | Out-File -Encoding UTF8 -FilePath $reportPath

# Erfolgsmeldung
Write-Host "✅ Report erfolgreich erstellt: $reportPath ($($data.Count) Einträge)"
