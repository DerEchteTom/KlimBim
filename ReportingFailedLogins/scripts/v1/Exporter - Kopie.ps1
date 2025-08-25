# ============================================
# Benutzersteuerung – hier kannst du alles einstellen Exporter.ps1
# ============================================
$Limit            = 5           # Anzahl Datensaetze aus der Datenbank
$UseTimeFilter    = $false      # Zeitfilter aktivieren (letzte 24 Stunden)
$UseUserFilter    = $false      # Benutzerfilter aktivieren (excludedUsers.json)
$UseFieldsFilter  = $true       # Nur Felder mit "enabled": true verwenden
$EnableHTML       = $true       # HTML-Ausgabe aktivieren
$ShowStep         = 'HTML'      # Optionen: Raw, PSObjects, AfterTime, AfterUser, HTML

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

# WICHTIG: Alle Felder für SQL-Abfrage verwenden, damit Button später alle anzeigen kann
$columnsList = $fields.PSObject.Properties.Name -join ", "

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
        $lastImport = (Get-Item $dbFile).LastWriteTime
        $lastImportStr = $lastImport.ToString("yyyy-MM-dd HH:mm")
        $dateStamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
        $targetPath = Join-Path $reportDir "FailedLogons_$dateStamp.html"

# ============================================
# HTML-Generierung mit Sprachumschaltung
# ============================================

$lang = "de"  # oder "en"

$htmlOut = @"
<!DOCTYPE html>
<html lang='$lang'>
<head>
  <meta charset='utf-8'/>
  <title>Failed Logons Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 20px; font-size: 13px; }
    table { border-collapse: collapse; width: max-content; overflow-x: auto; }
    thead { background-color: #007acc; color: white; }
    tr:nth-child(even) { background-color: #f2f2f2; }
    th, td { padding: 6px 10px; border: 1px solid #ddd; white-space: nowrap; }
    .hidden { display: none; }
    #toggleBtn { margin-bottom: 10px; }
    #importDate { padding: 4px; display: inline-block; }
    .age-warning { background-color: #fff3cd; }
    .age-alert { background-color: #ffeeba; }
    .age-critical { background-color: #f8d7da; }
  </style>
</head>
<body>
  <h2>Failed Logons Report</h2>
  <p>Report generated: <strong>$(Get-Date -Format "yyyy-MM-dd HH:mm")</strong></p>
  <p>Last database update: <span id='importDate'>$lastImportStr</span></p>
  <button id='toggleBtn' onclick='showAll()'>Show all columns</button>
  <div style='overflow-x:auto;'>
    <table id='reportTable'>
      <thead>
        <tr>
"@
foreach ($f in $fields.PSObject.Properties | Sort-Object { $_.Value.position }) {
    $name = $f.Name
    $enabled = $f.Value.enabled
    $label = if ($f.Value.label -and $f.Value.label[$lang]) { $f.Value.label[$lang] } else { $name }
    $class = if (-not $enabled) { "class='hidden'" } else { "" }
    $htmlOut += "          <th data-field='$name' $class>$label</th>`n"
}

$htmlOut += "        </tr>`n      </thead>`n      <tbody>`n"

foreach ($r in $rows) {
    $htmlOut += "        <tr>`n"
    foreach ($f in $fields.PSObject.Properties | Sort-Object { $_.Value.position }) {
        $name = $f.Name
        $enabled = $f.Value.enabled
        $class = if (-not $enabled) { "class='hidden'" } else { "" }

        if ($r.PSObject.Properties[$name]) {
            $value = $r.PSObject.Properties[$name].Value

            # Formatierung für Timestamp
            if ($name -match "Timestamp" -and $value) {
                try {
                    $value = ([datetime]$value).ToString("yyyy-MM-dd HH:mm:ss")
                } catch {
                    # Falls Umwandlung fehlschlägt, Originalwert behalten
                }
            }

            # Nur Dateiname anzeigen bei Pfadangaben
            if ($name -match "TransitedServices|ImagePath|ExecutablePath|TargetPath" -and $value) {
                $value = [System.IO.Path]::GetFileName($value)
            }
        } else {
            $value = ""
        }

        $htmlOut += "          <td data-field='$name' $class>$value</td>`n"
    }
    $htmlOut += "        </tr>`n"
}


$htmlOut += @"
      </tbody>
    </table>
  </div>

  <script>
    const thresholds = { warning:1, alert:3, critical:7 };
    const importDate = new Date(document.getElementById('importDate').innerText);
    const age = (Date.now() - importDate.getTime()) / 86400000;

    const importElement = document.getElementById('importDate');
    if (age >= thresholds.critical) importElement.classList.add('age-critical');
    else if (age >= thresholds.alert) importElement.classList.add('age-alert');
    else if (age >= thresholds.warning) importElement.classList.add('age-warning');

    function showAll() {
      document.querySelectorAll('.hidden').forEach(el => el.classList.remove('hidden'));
    }
  </script>
</body>
</html>
"@

# HTML-Datei speichern
$htmlOut | Set-Content -Encoding UTF8 $targetPath
Write-Host ""
Write-Host "HTML-Datei gespeichert unter: $targetPath"
    }  # schließt 'HTML'
}      # schließt switch
