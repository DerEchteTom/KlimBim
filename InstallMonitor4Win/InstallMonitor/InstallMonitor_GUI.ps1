<#
  InstallMonitor_GUI.ps1
  Vollständig mit:
    - Auto-Refresh
    - ID-Spalte
    - Kombiniertem Export (CSV+HTML)
    - Initial-Snapshot-Button
    - RunLog-Protokollierung
    - Deutschem Dropdown-Text & E-Mail-Eingabe
  Stand: 2025-07-24
#>

# Assemblies für GUI laden
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# PSSQLite-Modul sicherstellen und importieren
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module PSSQLite -ErrorAction Stop

# SMTP-Grundkonfiguration
$SmtpServer = '172.16.30.21'
$SmtpPort   = 25
$MailFrom   = 'monitor@technoteam.de'

# Pfad zur SQLite-DB
$dbFile = Join-Path $PSScriptRoot 'data\installations.db'

# ────────────────────────────────────────────────────────────────────────
# DB-Migration: Spalte Exported, Metadata LastExport, Tabelle RunLog
# ────────────────────────────────────────────────────────────────────────

# Spalte Exported hinzufügen, falls sie fehlt
$cols = Invoke-SqliteQuery -DataSource $dbFile -Query "PRAGMA table_info(Installations);"
if (-not ($cols.name -contains 'Exported')) {
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "ALTER TABLE Installations ADD COLUMN Exported INTEGER DEFAULT 0;"
}

# Metadata-Eintrag LastExport prüfen/erstellen
$le = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastExport';"
if ($le.Count -eq 0) {
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "INSERT INTO Metadata(Key,Value) VALUES('LastExport', datetime('now','-1 day'));"
}

# Tabelle RunLog anlegen, falls nicht vorhanden
Invoke-SqliteQuery -DataSource $dbFile -Query @'
CREATE TABLE IF NOT EXISTS RunLog (
  RunID    INTEGER PRIMARY KEY AUTOINCREMENT,
  RunDate  TEXT,
  NewCount INTEGER
);
'@

# Letzte Läufe aus Metadata laden
$lrRec      = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastRun';"
$lastRun    = if ($lrRec) { [datetime]$lrRec.Value } else { Get-Date '1970-01-01' }
$leRec      = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastExport';"
$lastExport = if ($leRec) { [datetime]$leRec.Value } else { Get-Date '1970-01-01' }
# Fenster und Haupt-Layout
$form = New-Object Windows.Forms.Form
$form.Text           = 'Installation Monitor'
$form.Size           = '960,600'
$form.StartPosition  = 'CenterScreen'

$table = New-Object Windows.Forms.TableLayoutPanel
$table.Dock           = 'Fill'
$table.RowCount       = 2
$table.ColumnCount    = 1
$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',60)))
$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))

# Oberes Panel für Controls
$panel = New-Object Windows.Forms.Panel
$panel.Dock      = 'Fill'
$panel.BackColor = 'WhiteSmoke'

# DataGridView für Installations-Liste
$grid = New-Object Windows.Forms.DataGridView
$grid.ReadOnly                    = $true
$grid.Dock                        = 'Fill'
$grid.AutoSizeColumnsMode         = 'AllCells'
$grid.AutoSizeRowsMode            = 'AllCells'
$grid.AllowUserToAddRows          = $false
$grid.ColumnHeadersHeightSizeMode = 'AutoSize'
$grid.ColumnHeadersVisible        = $true
$grid.RowHeadersVisible           = $false

# Panels in Layout einfügen
$table.Controls.Add($panel, 0, 0)
$table.Controls.Add($grid, 0, 1)
$form.Controls.Add($table)
# 1) Filter-Dropdown (deutsche Texte)
$cbFilter = New-Object Windows.Forms.ComboBox
$cbFilter.DropDownStyle = 'DropDownList'
$cbFilter.Left          = 10
$cbFilter.Top           = 18
$cbFilter.Width         = 260
$cbFilter.Items.AddRange(@(
  'Alle Installationen',
  'Neu seit letztem Programmstart',
  'Neu seit letztem Export (CSV/HTML)',
  'Noch nicht exportierte Einträge',
  'Neu gegenüber letztem CSV-Snapshot'
))
$cbFilter.SelectedIndex = 0
$panel.Controls.Add($cbFilter)

# Auto-Refresh bei Filterwechsel
$cbFilter.Add_SelectedIndexChanged({ LoadData })

# 2) Empfänger-E-Mail
$lblRecipient = New-Object Windows.Forms.Label
$lblRecipient.Text     = 'Empfänger-E-Mail:'
$lblRecipient.AutoSize = $true
$lblRecipient.Left     = 285
$lblRecipient.Top      = 21
$panel.Controls.Add($lblRecipient)

$txtRecipient = New-Object Windows.Forms.TextBox
$txtRecipient.Width    = 240
$txtRecipient.Left     = 390
$txtRecipient.Top      = 18
$txtRecipient.Text     = 'it@technoteam.de'
$panel.Controls.Add($txtRecipient)

# 3) Buttons: Refresh, Mail, Export, Initial-Snapshot
$btnRef    = New-Object Windows.Forms.Button -Property @{
    Text  = 'Refresh'
    Width = 90; Left=650; Top=15
}
$btnMail   = New-Object Windows.Forms.Button -Property @{
    Text  = 'E-Mail senden'
    Width = 110; Left=750; Top=15
}
$btnExport = New-Object Windows.Forms.Button -Property @{
    Text  = 'Export (CSV+HTML)'
    Width = 140; Left=870; Top=15
}
$btnInit   = New-Object Windows.Forms.Button -Property @{
    Text  = 'Initial-Snapshot'
    Width = 140; Left=870; Top=15  # ggf. nach rechts rücken
}
# Init-Button neben Export?
$btnInit.Left = 1020

$panel.Controls.AddRange(@($btnRef,$btnMail,$btnExport,$btnInit))
# Funktion zum Laden & Filtern
function LoadData {
    switch ($cbFilter.SelectedItem) {
      'Alle Installationen' {
        $raw = Invoke-SqliteQuery -DataSource $dbFile `
               -Query "SELECT * FROM Installations ORDER BY TimeLogged DESC"
      }
      'Neu seit letztem Programmstart' {
        $raw = Invoke-SqliteQuery -DataSource $dbFile `
               -Query "SELECT * FROM Installations WHERE TimeLogged > @lr ORDER BY TimeLogged DESC" `
               -SqlParameters @{ lr = $lastRun.ToString('yyyy-MM-dd HH:mm:ss') }
      }
      'Neu seit letztem Export (CSV/HTML)' {
        $raw = Invoke-SqliteQuery -DataSource $dbFile `
               -Query "SELECT * FROM Installations WHERE TimeLogged > @le ORDER BY TimeLogged DESC" `
               -SqlParameters @{ le = $lastExport.ToString('yyyy-MM-dd HH:mm:ss') }
      }
      'Noch nicht exportierte Einträge' {
        $raw = Invoke-SqliteQuery -DataSource $dbFile `
               -Query "SELECT * FROM Installations WHERE Exported=0 ORDER BY TimeLogged DESC"
      }
      'Neu gegenüber letztem CSV-Snapshot' {
        $folder  = Join-Path $PSScriptRoot 'export'
        $lastCsv = Get-ChildItem -Path $folder -Filter 'Installations_Export_*.csv' `
                   | Sort LastWriteTime -Descending | Select-Object -First 1
        if (-not $lastCsv) {
          [Windows.Forms.MessageBox]::Show("Kein vorheriger CSV-Snapshot gefunden.","Info")
          return
        }
        $prev = Import-Csv $lastCsv.FullName | Select-Object -ExpandProperty DisplayName
        if ($prev.Count -gt 0) {
          $quoted   = ($prev | ForEach-Object { "'$_'" })
          $inClause = $quoted -join ','
          $raw = Invoke-SqliteQuery -DataSource $dbFile `
                 -Query "SELECT * FROM Installations WHERE DisplayName NOT IN ($inClause) ORDER BY TimeLogged DESC"
        }
        else { $raw = @() }
      }
    }

    # DataTable füllen
    $dt = New-Object System.Data.DataTable
    if ($raw.Count -gt 0) {
      $raw[0].PSObject.Properties.Name | ForEach-Object { [void]$dt.Columns.Add($_) }
      foreach ($r in $raw) {
        [void]$dt.Rows.Add($r.PSObject.Properties.Value)
      }
    }

    $grid.DataSource = $dt
    FormatRows
    AddRowNumbers
}

# Zeilen einfärben
function FormatRows {
  for ($i=0; $i -lt $grid.Rows.Count; $i++) {
    $row = $grid.Rows[$i]
    $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Black
    switch ($cbFilter.SelectedItem) {
      'Neu seit letztem Programmstart' {
        $ts = [datetime]$row.Cells['TimeLogged'].Value
        if ($ts -gt $lastRun) { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red }
      }
      'Neu seit letztem Export (CSV/HTML)' {
        $ts = [datetime]$row.Cells['TimeLogged'].Value
        if ($ts -gt $lastExport) { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red }
      }
      'Noch nicht exportierte Einträge' {
        if ([int]$row.Cells['Exported'].Value -eq 0) {
          $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red
        }
      }
      'Neu gegenüber letztem CSV-Snapshot' {
        $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red
      }
    }
  }
}

# ID-Spalte 1–n
function AddRowNumbers {
  if ($grid.Columns['ID']) { $grid.Columns.Remove('ID') }
  $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
  $col.Name       = 'ID'
  $col.HeaderText = 'ID'
  $col.ReadOnly   = $true
  $grid.Columns.Add($col)
  $grid.Columns['ID'].DisplayIndex = $grid.Columns.Count - 1
  for ($i=0; $i -lt $grid.Rows.Count; $i++) {
    $grid.Rows[$i].Cells['ID'].Value = $i + 1
  }
}

# Initial-Snapshot-Routine
function InitializeSnapshot {
  # Beispiel: Installationen aus Registry-Uninstall auslesen
  $apps = Get-ChildItem HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall |
          ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            [PSCustomObject]@{ Name=$p.DisplayName; Date=$p.InstallDate }
          } | Where-Object { $_.Name }

  # Tabelle Installations leeren
  Invoke-SqliteQuery -DataSource $dbFile -Query "DELETE FROM Installations;"

  # Neue Einträge schreiben
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  foreach ($app in $apps) {
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "INSERT INTO Installations(DisplayName,InstallDate,TimeLogged,Exported)
              VALUES(@name,@date,@ts,0);" `
      -SqlParameters @{
        name = $app.Name
        date = $app.Date
        ts   = $ts
      }
  }

  # RunLog protokollieren (Initial = Gesamtanzahl)
  $count = $apps.Count
  Invoke-SqliteQuery -DataSource $dbFile `
    -Query "INSERT INTO RunLog(RunDate,NewCount) VALUES(datetime('now'),@cnt);" `
    -SqlParameters @{ cnt = $count }

  # Metadata LastRun & LastExport aktualisieren
  Invoke-SqliteQuery -DataSource $dbFile `
    -Query "UPDATE Metadata SET Value=datetime('now') WHERE Key IN('LastRun','LastExport');"

  # Skript-Variable updaten
  $lastRun    = Get-Date
  $lastExport = Get-Date

  LoadData
  [Windows.Forms.MessageBox]::Show(
    "Initial-Snapshot fertig: $count Einträge.","Info"
  )
}

# Eventhandler
$btnRef.Add_Click({ LoadData })

$btnMail.Add_Click({
  $new = Invoke-SqliteQuery -DataSource $dbFile `
         -Query "SELECT * FROM Installations WHERE TimeLogged > @lr" `
         -SqlParameters @{ lr = $lastRun.ToString('yyyy-MM-dd HH:mm:ss') }

  if ($new.Count -eq 0) {
    [Windows.Forms.MessageBox]::Show("Keine neuen Installationen seit $lastRun.","Info")
    return
  }

  $body = "Neue Installationen seit $lastRun`r`n"
  $new | ForEach-Object { $body += "$($_.DisplayName) (Installiert am $($_.InstallDate))`r`n" }

  try {
    Send-MailMessage `
      -SmtpServer $SmtpServer -Port $SmtpPort `
      -From $MailFrom -To $txtRecipient.Text `
      -Subject "InstallMonitor – neue Installationen seit $lastRun" `
      -Body $body
    [Windows.Forms.MessageBox]::Show("E-Mail gesendet an $($txtRecipient.Text).","Info")
  }
  catch {
    [Windows.Forms.MessageBox]::Show("Fehler beim Versand:`r`n$($_.Exception.Message)","Fehler")
  }

  # Lauf protokollieren
  $newCount = $new.Count
  Invoke-SqliteQuery -DataSource $dbFile `
    -Query "INSERT INTO RunLog(RunDate,NewCount) VALUES(datetime('now'),@cnt);" `
    -SqlParameters @{ cnt = $newCount }
})

$btnExport.Add_Click({
  $folder = Join-Path $PSScriptRoot 'export'
  New-Item -Path $folder -ItemType Directory -Force | Out-Null

  # CSV-Snapshot-Modus prüfen
  if ($cbFilter.SelectedItem -eq 'Neu gegenüber letztem CSV-Snapshot') {
    $lastCsv = Get-ChildItem -Path $folder -Filter 'Installations_Export_*.csv' |
               Sort LastWriteTime -Descending | Select-Object -First 1
    if (-not $lastCsv) {
      [Windows.Forms.MessageBox]::Show("Kein vorheriger CSV-Snapshot gefunden.","Fehler")
      return
    }
  }

  if ($grid.Rows.Count -eq 0) {
    [Windows.Forms.MessageBox]::Show("Keine Daten zum Exportieren.","Export")
    return
  }

  $ts       = Get-Date -Format 'yyyyMMdd_HHmmss'
  $csvPath  = Join-Path $folder "Installations_Export_$ts.csv"
  $htmlPath = Join-Path $folder "Installationen_$ts.html"

  try {
    # CSV
    $grid.DataSource | ForEach-Object {
      ($_ | Select-Object * | ConvertTo-Csv -NoTypeInformation) -join "`n"
    } | Set-Content -Encoding UTF8 -Path $csvPath

    # HTML
    $html = @"
<html><head><title>InstallMonitor Export</title>
<style>body{font-family:Segoe UI;margin:20px}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:8px}</style>
</head><body><h2>Export vom $(Get-Date)</h2><table><tr>
"@
    foreach ($c in $grid.Columns) { $html += "<th>$($c.HeaderText)</th>" }
    $html += "</tr>`n"
    foreach ($r in $grid.Rows) {
      $html += "<tr>"
      for ($i=0; $i -lt $grid.Columns.Count; $i++) {
        $html += "<td>$($r.Cells[$i].Value)</td>"
      }
      $html += "</tr>`n"
    }
    $html += '</table></body></html>'
    $html | Set-Content -Encoding UTF8 -Path $htmlPath

    # Flags & Metadata updaten
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "UPDATE Metadata SET Value=datetime('now') WHERE Key='LastExport';"
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "UPDATE Installations SET Exported=1 WHERE Exported=0;"

    # Lauf protokollieren
    $param    = @{ lr = $lastRun.ToString('yyyy-MM-dd HH:mm:ss') }
    $newCount = Invoke-SqliteQuery -DataSource $dbFile `
                -Query "SELECT COUNT(*) AS C FROM Installations WHERE TimeLogged> @lr;" `
                -SqlParameters $param | Select-Object -ExpandProperty C
    Invoke-SqliteQuery -DataSource $dbFile `
      -Query "INSERT INTO RunLog(RunDate,NewCount) VALUES(datetime('now'),@cnt);" `
      -SqlParameters @{ cnt = $newCount }

    $lastExport = Get-Date
    [Windows.Forms.MessageBox]::Show("Export erfolgreich!`r`n$folder","Export")
    LoadData
  }
  catch {
    [Windows.Forms.MessageBox]::Show("Fehler beim Export:`r`n$($_.Exception.Message)","Fehler")
  }
})

$btnInit.Add_Click({ InitializeSnapshot })

# GUI laden und anzeigen
$form.Add_Load({ LoadData })
[void]$form.ShowDialog()