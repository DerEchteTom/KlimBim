<#
.SYNOPSIS
  Exportiert die Tabelle FailedLogons aus SQLite nach HTML.
#>

. "$PSScriptRoot\..\Config-Helper.ps1"

# 1) Pfade & Konfiguration laden
$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath
$reportDir     = Get-ReportDirPath
$fields        = Get-FieldsConfig
$excludedUsers = Get-ExcludedUsers

# 2) Sichtbare Spalten definieren
$sortOrder = @(
    'TimeStamp',
    'SubjectUserName',
    'TargetUserName',
    'LogonTypeName',
    'SourceNetworkAddress',
    'ResolvedHost',
    'ProcessName',
    'FailureReason'
)

$visibleCols = $sortOrder | Where-Object { $fields.$_ -eq $true }

if (-not $visibleCols) {
    throw "Keine Spalten in fields.json aktiviert oder Sortierung passt nicht."
}

# 3) SQL-Abfrage
$sql = "SELECT $($visibleCols -join ', ') FROM FailedLogons ORDER BY TimeStamp DESC;"
$csvOutput = & $sqliteExe -header -csv $dbFile $sql
if ($LASTEXITCODE -ne 0) { throw "sqlite3-Abfrage fehlgeschlagen. Exitcode: $LASTEXITCODE" }

$data = $csvOutput | ConvertFrom-Csv | Where-Object { -not ($excludedUsers -contains $_.SubjectUserName) }
if (-not $data) { throw "Keine Datensätze gefunden oder Parsing fehlgeschlagen." }

# 4) HTML erzeugen
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$outFile   = Join-Path $reportDir ("FailedLogonsReport_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")

$html = @"  
<!DOCTYPE html>
<html lang='de'>
<head><meta charset='UTF-8'><title>Fehlgeschlagene Logons</title>
<style>
  body { font-family: Segoe UI, sans-serif; margin: 20px; }
  h1 { font-size: 1.5em; }
  table { border-collapse: collapse; width: 100%; margin-top: 20px; }
  th, td { padding: 8px; border: 1px solid #ddd; text-align: left; }
  th { background-color: #f4f4f4; }
  tr:nth-child(even) { background-color: #fbfbfb; }
  .meta { font-size: 0.9em; color: #666; margin-bottom: 10px; }
</style>
</head><body>
<h1>Fehlgeschlagene Logons</h1>
<div class='meta'>Erstellt am: $timestamp</div>
<table><thead><tr>
"@

foreach ($col in $visibleCols) { $html += "<th>$col</th>" }
$html += "</tr></thead><tbody>"

foreach ($row in $data) {
    $html += "<tr>"
    foreach ($col in $visibleCols) {
        $val = $row.$col
        if ($col -eq 'TimeStamp') {
            try { $val = ([datetime]$val).ToString('dd.MM.yyyy HH:mm:ss') } catch { }
        }
        $safe = $val -replace "<", "&lt;" -replace ">", "&gt;"
        $html += "<td>$safe</td>"
    }
    $html += "</tr>"
}

$html += "</tbody></table></body></html>"
$html | Out-File -FilePath $outFile -Encoding UTF8

Write-Host "✅ HTML-Report erfolgreich erstellt: $outFile"