<#
.SYNOPSIS
Generiert einen HTML-Report aus der SQLite-Datenbank basierend auf Fields-Konfiguration, ExcludedUsers und Zeitfilter.

.VERSION
v1.0 — Erstversion mit Datenbankabfrage, Filterung und HTML-Export

.AUTHOR
T & Copilot
#>

# Lade Hilfsfunktionen
. "$PSScriptRoot\..\Config-Helper.ps1"

# 🔧 Konfiguration laden
$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath
$reportDir     = Get-ReportDirPath
$fields        = Get-FieldsConfig
$excludedUsers = Get-ExcludedUsers

# 🧪 Diagnose: Konfigurationsübersicht
Write-Host "`n🧪 Konfigurations-Check:"
Write-Host "• SQLite Pfad: $sqliteExe"
Write-Host "• Datenbank: $dbFile"
Write-Host "• Report-Ordner: $reportDir"
Write-Host "• Fields geladen: $($fields.PSObject.Properties.Count)"
Write-Host "• ExcludedUsers: $($excludedUsers -join ', ')"


# 🕒 Zeitfilter: letzte 24 Stunden
$hoursBack  = 24
$sinceTime  = (Get-Date).AddHours(-$hoursBack).ToString("o")

# 🧩 Alle Feldnamen aus fields.json
$allFieldNames = $fields.PSObject.Properties.Name
$columnsList   = $allFieldNames -join ", "

# SQL-Abfrage vorbereiten
$sqlQuery = "SELECT $columnsList FROM FailedLogons WHERE TimeStamp >= '$sinceTime';"

# SQLite ausführen und CSV-Daten holen
$csvOutput = & "$sqliteExe" -header -csv "$dbFile" "$sqlQuery"
if ($LASTEXITCODE -ne 0) { throw "sqlite3-Abfrage fehlgeschlagen. Exitcode: $LASTEXITCODE" }

# CSV-Daten parsen und Benutzer herausfiltern
$data = $csvOutput | ConvertFrom-Csv |
    Where-Object {
        -not ($excludedUsers -contains $_.SubjectUserName) -and
        -not ($excludedUsers -contains $_.TargetUserName)
    }
# 🧾 Zeilen in Objekte umwandeln
$data = $csvOutput | ConvertFrom-Csv |
    Where-Object {
        -not ($excludedUsers -contains $_.SubjectUserName) -and
        -not ($excludedUsers -contains $_.TargetUserName)
    }
    
# 🧪 Diagnose: Datencheck
Write-Host "`n🧪 Datensatz-Check:"
Write-Host "• Anzahl geladener Datensätze: $($data.Count)"

if ($data.Count -gt 0) {
    Write-Host "• Feldnamen im ersten Datensatz:"
    $data[0] | Get-Member | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { Write-Host "   - $($_.Name)" }

    Write-Host "`n• Beispielinhalt:"
    $data[0] | Format-List
} else {
    Write-Host "⚠️ Keine Datensätze gefunden nach Filterung!"
}


# Sichtbare Felder aus neuer fields.json-Struktur
$visibleFields = $fields.PSObject.Properties |
    Where-Object { $_.Value.enabled -eq $true } |
    Sort-Object { $_.Value.position }


# 📋 Tabellenkopf erzeugen
$tableHeader = ($visibleFields | ForEach-Object {
    if ($_.Value.label) {
        "<th>$($_.Value.label)</th>"
    } else {
        "<th>$($_.Name)</th>"
    }
}) -join "`n"

# 📄 HTML-Zeilen generieren
$tableRows = foreach ($row in $data) {
    $cells = foreach ($field in $visibleFields) {
        "<td>$($row[$field.Name])</td>"
    }
    "<tr>`n" + ($cells -join "`n") + "`n</tr>"
}

# 📦 HTML-Inhalt zusammensetzen
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$reportPath = Join-Path $reportDir "Report_$timestamp.html"
$html = @"
<html>
<head><title>Login Report</title></head>
<body>
<h2>Report: $timestamp</h2>
<table border="0">
<tr>
$tableHeader
</tr>
$tableRows
</table>
</body>
</html>
"@

# 💾 HTML speichern
$html | Out-File -Encoding UTF8 -FilePath $reportPath

Write-Host "✅ Report erstellt: $reportPath"