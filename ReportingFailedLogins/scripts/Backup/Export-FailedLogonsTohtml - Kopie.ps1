<# 
.SYNOPSIS
  Exportiert die Tabelle FailedLogons aus SQLite nach HTML.
  Spaltenauswahl erfolgt über fields.json.
  Der Report wird in das Verzeichnis gespeichert, das in config.json unter "ReportDir" angegeben ist.
#>

# 1) Helpers laden
$sd = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $sd "..\Path.ps1")          -CallerScriptPath $MyInvocation.MyCommand.Path
. (Join-Path $sd "..\Config-Helper.ps1") -CallerScriptPath $MyInvocation.MyCommand.Path

# 2) Config und Projektpfade
$config      = Load-Config
$projectRoot = Get-ProjectRoot
$sqliteExe   = Join-Path $projectRoot $config.SqliteExe
$dbFile      = Join-Path $projectRoot $config.DatabaseFile
$reportDir   = Join-Path $projectRoot $config.ReportDir
$fieldsFile  = Join-Path $sd $config.FieldsFile

# 3) Pfade prüfen
if (-not (Test-Path $dbFile))     { throw "Datenbank nicht gefunden: $dbFile" }
if (-not (Test-Path $sqliteExe))  { throw "sqlite3.exe nicht gefunden: $sqliteExe" }
if (-not (Test-Path $fieldsFile)) { throw "fields.json nicht gefunden: $fieldsFile" }
if (-not (Test-Path $reportDir))  { New-Item -Path $reportDir -ItemType Directory -Force | Out-Null }

# 4) Sichtbare Spalten laden
$flags = Get-Content -Path $fieldsFile | ConvertFrom-Json

# Feste Reihenfolge definieren
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

# Nur aktivierte Spalten in definierter Reihenfolge
$visibleCols = $sortOrder | Where-Object { $flags.$_ }

if (-not $visibleCols) {
    throw "Keine Spalten in fields.json aktiviert. Bitte prüfen."
}

# 5) SQL bauen
$columns = $visibleCols -join ', '
$sql     = "SELECT $columns FROM FailedLogons ORDER BY TimeStamp DESC;"

# 6) sqlite3.exe aufrufen
$csvOutput = & $sqliteExe -header -csv $dbFile $sql
if ($LASTEXITCODE -ne 0) {
    throw "sqlite3-Abfrage fehlgeschlagen. Exitcode: $LASTEXITCODE"
}

$data = $csvOutput | ConvertFrom-Csv
if (-not $data) {
    throw "CSV-Parsing fehlgeschlagen oder keine Datensätze gefunden."
}

# 7) HTML Grundstruktur
$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$outFile   = Join-Path $reportDir ("FailedLogonsReport_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")

$htmlHeader = @"
<!DOCTYPE html>
<html lang='de'>
<head>
  <meta charset='UTF-8'>
  <title>Fehlgeschlagene Logons</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 20px; }
    h1 { font-size: 1.5em; }
    table { border-collapse: collapse; width: 100%; margin-top: 20px; }
    th, td { padding: 8px; border: 1px solid #ddd; text-align: left; }
    th { background-color: #f4f4f4; }
    tr:nth-child(even) { background-color: #fbfbfb; }
    .meta { font-size: 0.9em; color: #666; margin-bottom: 10px; }
  </style>
</head>
<body>
  <h1>Fehlgeschlagene Logons</h1>
  <div class="meta">Erstellt am: $timestamp</div>
  <table>
    <thead>
      <tr>
"@

foreach ($col in $visibleCols) {
    $htmlHeader += "        <th>$col</th>`n"
}
$htmlHeader += "      </tr>`n    </thead>`n    <tbody>`n"

# 9) Tabellenzeilen mit TimeStamp-Formatierung
$htmlRows = ""
foreach ($row in $data) {
    $htmlRows += "      <tr>`n"
    foreach ($col in $visibleCols) {
        $value = $row.$col -as [string]

        if ($col -eq 'TimeStamp') {
            try {
                $value = ([datetime]$value).ToString('dd.MM.yyyy HH:mm:ss')
            } catch {
                $value = $row.$col
            }
        }

        $safeValue = $value -replace "<", "&lt;" -replace ">", "&gt;"
        $htmlRows += "        <td>$safeValue</td>`n"
    }
    $htmlRows += "      </tr>`n"
}

# 10) Abschließen
$htmlFooter = @"
    </tbody>
  </table>
</body>
</html>
"@

# 11) Alles zusammenfügen
$htmlComplete = $htmlHeader + $htmlRows + $htmlFooter
$htmlComplete | Out-File -FilePath $outFile -Encoding UTF8

Write-Host "HTML-Report erfolgreich erstellt: $outFile"