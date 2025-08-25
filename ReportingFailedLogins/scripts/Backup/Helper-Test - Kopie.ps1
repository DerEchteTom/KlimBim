# ============================================
# Benutzersteuerung – hier kannst du alles einstellen
# ============================================
$Limit            = 5           # Anzahl Datensätze aus der Datenbank
$UseTimeFilter    = $false      # Zeitfilter aktivieren (letzte 24 Stunden)
$UseUserFilter    = $false      # Benutzerfilter aktivieren (excludedUsers.json)
$UseFieldsFilter  = $true       # Nur Felder mit "enabled": true verwenden
$EnableHTML       = $true       # HTML-Ausgabe aktivieren
$ShowStep         = 'HTML'      # Optionen: Raw, PSObjects, AfterTime, AfterUser, HTML

# ============================================
# Erklärung zu $Limit
# ============================================
# $Limit steuert die maximale Anzahl der Datensätze, die aus der Datenbank gelesen werden.
# Mögliche Zustände:
# - $Limit = 5       → Nur 5 Einträge werden abgefragt (ideal für Tests)
# - $Limit = 1000    → Größere Datenmengen für produktive Auswertung
# - $Limit = $null   → Kein LIMIT in der SQL-Abfrage → Alle Einträge werden geladen

# ============================================
# Hilfsfunktionen laden
# ============================================
. "$PSScriptRoot\..\Config-Helper.ps1"
$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath
$fields        = Get-FieldsConfig
$excludedUsers = Get-ExcludedUsers
$reportDir     = Get-ReportDirPath

# ============================================
# Felder aus fields.json verarbeiten
# ============================================
if ($UseFieldsFilter) {
    $visibleFields = $fields.PSObject.Properties |
        Where-Object { $_.Value.enabled } |
        Sort-Object { if ($_.Value.position) { $_.Value.position } else { 999 } }
} else {
    $visibleFields = $fields.PSObject.Properties |
        Sort-Object { if ($_.Value.position) { $_.Value.position } else { 999 } }
}

$columnsList = $visibleFields.Name -join ", "

# ============================================
# SQL-Abfrage vorbereiten
# ============================================
$sqlWhere = ""
if ($UseTimeFilter) {
    $sqlWhere = "WHERE datetime(substr(TimeStamp,1,19)) >= datetime('now','-24 hours')"
}

$sqlLimit = if ($Limit) { "LIMIT $Limit" } else { "" }
$sqlQuery = "SELECT $columnsList FROM FailedLogons $sqlWhere $sqlLimit;"

# ============================================
# Verarbeitungsschritte
# ============================================
switch ($ShowStep) {
    'HTML' {
        Write-Host ""
        Write-Host "--- HTML-Vorschau und Dateiausgabe ---"
        $csv  = & $sqliteExe -header -csv $dbFile $sqlQuery
        $objs = $csv | ConvertFrom-Csv

        $filteredTime = if ($UseTimeFilter) {
            $objs | Where-Object {
                [datetime]::Parse($_.TimeStamp.Substring(0,19)) -ge (Get-Date).AddHours(-24)
            }
        } else {
            $objs
        }

        $filteredUsers = if ($UseUserFilter) {
            $filteredTime | Where-Object {
                -not ($excludedUsers -contains $_.SubjectUserName) -and
                -not ($excludedUsers -contains $_.TargetUserName)
            }
        } else {
            $filteredTime
        }

        $rows = $filteredUsers

        # Tabellenkopf
        $thArray = $visibleFields | ForEach-Object {
            $label = if ($_.Value.label) { $_.Value.label } else { $_.Name }
            "<th>$label</th>"
        }
        $th = $thArray -join "`n"

        # HTML-Ausgabe in Konsole
        Write-Host "<table>"
        Write-Host "  <tr>`n$th`n  </tr>"

        $htmlOut = @()
        $htmlOut += "<table>"
        $htmlOut += "  <tr>`n$th`n  </tr>"

        foreach ($r in $rows) {
            $tdArray = @()
            foreach ($f in $visibleFields) {
                $value = $r | Select-Object -ExpandProperty $f.Name
                $tdArray += "<td>$value</td>"
            }
            $td = $tdArray -join "`n"
            Write-Host "  <tr>`n$td`n  </tr>"
            $htmlOut += "  <tr>`n$td`n  </tr>"
        }

        Write-Host "</table>"
        $htmlOut += "</table>"

        # HTML-Datei speichern
        $targetPath = Join-Path $reportDir "FailedLogons.html"
        $htmlOut | Set-Content -Encoding UTF8 $targetPath
        Write-Host "`n✔ HTML-Datei gespeichert unter: $targetPath"
    }

    default {
        Write-Warning "Ungültiger Wert für ShowStep: $ShowStep"
    }
}
