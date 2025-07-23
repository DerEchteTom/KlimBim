<#
  InstallMonitor_GUI.ps1
  Vollständiges GUI mit automatischem Refresh, ID-Spalte und kombiniertem Export
  Stand: 2025-07-24
#>

# Assemblies laden
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# PSSQLite-Modul sicherstellen und importieren
if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
    Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module PSSQLite -ErrorAction Stop

# SMTP-Konfiguration
$SmtpServer = '172.16.30.21'
$SmtpPort   = 25
$MailFrom   = 'monitor@technoteam.de'
$MailTo     = 'thomas.schmidt@technoteam.de'

# Datenbankpfad
$dbFile = Join-Path $PSScriptRoot 'data\installations.db'

# ─────────────────────────────────────────────────────────────────────────────
# DB-Migration: Spalte "Exported" & Metadata "LastExport" anlegen, falls nötig
# ─────────────────────────────────────────────────────────────────────────────
$cols = Invoke-SqliteQuery -DataSource $dbFile -Query "PRAGMA table_info(Installations);"
if (-not ($cols.name -contains 'Exported')) {
    Invoke-SqliteQuery -DataSource $dbFile `
        -Query "ALTER TABLE Installations ADD COLUMN Exported INTEGER DEFAULT 0;"
}
$le = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastExport';"
if ($le.Count -eq 0) {
    Invoke-SqliteQuery -DataSource $dbFile `
        -Query "INSERT INTO Metadata(Key,Value) VALUES('LastExport', datetime('now','-1 day'));"
}

# ─────────────────────────────────────────────────────────────────────────────
# Zeitpunkte LastRun & LastExport laden
# ─────────────────────────────────────────────────────────────────────────────
$lrRec      = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastRun';"
$lastRun    = if ($lrRec)      { [datetime]$lrRec.Value } else { Get-Date '1970-01-01' }
$leRec      = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastExport';"
$lastExport = if ($leRec)      { [datetime]$leRec.Value } else { Get-Date '1970-01-01' }

# ─────────────────────────────────────────────────────────────────────────────
# 1) GUI-Grundgerüst: Form, TableLayoutPanel, Panel, DataGridView
# ─────────────────────────────────────────────────────────────────────────────
$form = New-Object Windows.Forms.Form
$form.Text           = 'Installation Monitor'
$form.Size           = '900,600'
$form.StartPosition  = 'CenterScreen'

$table = New-Object Windows.Forms.TableLayoutPanel
$table.Dock          = 'Fill'
$table.RowCount      = 2
$table.ColumnCount   = 1
$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',50)))
$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))

$panel = New-Object Windows.Forms.Panel
$panel.Dock         = 'Fill'
$panel.BackColor    = 'WhiteSmoke'

$grid = New-Object Windows.Forms.DataGridView
$grid.ReadOnly                  = $true
$grid.Dock                      = 'Fill'
$grid.AutoSizeColumnsMode       = 'AllCells'
$grid.AutoSizeRowsMode          = 'AllCells'
$grid.AllowUserToAddRows        = $false
$grid.ColumnHeadersHeightSizeMode = 'AutoSize'
$grid.ColumnHeadersVisible      = $true
$grid.RowHeadersVisible         = $false

$table.Controls.Add($panel,0,0)
$table.Controls.Add($grid,0,1)
$form.Controls.Add($table)

# ─────────────────────────────────────────────────────────────────────────────
# 2) Bedienelemente im Panel: Filter-Combo, Buttons
# ─────────────────────────────────────────────────────────────────────────────
# Filter-Auswahl
$cbFilter = New-Object Windows.Forms.ComboBox
$cbFilter.DropDownStyle = 'DropDownList'
$cbFilter.Left          = 10
$cbFilter.Top           = 12
$cbFilter.Width         = 200
$cbFilter.Items.AddRange(@(
    'All installations',
    'New since last run',
    'New since last export',
    'Unexported (Exported=0)',
    'New since last CSV'
))
$cbFilter.SelectedIndex = 0
$panel.Controls.Add($cbFilter)

# Auto-Refresh bei Filterwechsel
$cbFilter.Add_SelectedIndexChanged({ LoadData })

# Buttons
$btnRef    = New-Object Windows.Forms.Button -Property @{ Text='Refresh';    Width=90;  Left=220; Top=10 }
$btnMail   = New-Object Windows.Forms.Button -Property @{ Text='Email New';   Width=90;  Left=320; Top=10 }
$btnExport = New-Object Windows.Forms.Button -Property @{ Text='Export';      Width=100; Left=430; Top=10 }

$panel.Controls.AddRange(@($btnRef,$btnMail,$btnExport))

# ─────────────────────────────────────────────────────────────────────────────
# 3) Hilfsfunktionen: LoadData, FormatRows, AddRowNumbers
# ─────────────────────────────────────────────────────────────────────────────
function LoadData {
    switch ($cbFilter.SelectedItem) {
        'All installations' {
            $raw = Invoke-SqliteQuery -DataSource $dbFile `
                   -Query "SELECT * FROM Installations ORDER BY TimeLogged DESC"
        }
        'New since last run' {
            $raw = Invoke-SqliteQuery -DataSource $dbFile `
                   -Query "SELECT * FROM Installations WHERE TimeLogged > @lr ORDER BY TimeLogged DESC" `
                   -SqlParameters @{ lr = $lastRun.ToString('yyyy-MM-dd HH:mm:ss') }
        }
        'New since last export' {
            $raw = Invoke-SqliteQuery -DataSource $dbFile `
                   -Query "SELECT * FROM Installations WHERE TimeLogged > @le ORDER BY TimeLogged DESC" `
                   -SqlParameters @{ le = $lastExport.ToString('yyyy-MM-dd HH:mm:ss') }
        }
        'Unexported (Exported=0)' {
            $raw = Invoke-SqliteQuery -DataSource $dbFile `
                   -Query "SELECT * FROM Installations WHERE Exported = 0 ORDER BY TimeLogged DESC"
        }
        'New since last CSV' {
            $folder = Join-Path $PSScriptRoot 'export'
            $csv = Get-ChildItem -Path $folder -Filter 'Installations_Export_*.csv' `
                   | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($csv) {
                $prev = Import-Csv $csv.FullName | Select-Object -Expand DisplayName
                if ($prev.Count) {
                    $in = $prev | ForEach-Object { "'$_'" } -join ','
                    $raw = Invoke-SqliteQuery -DataSource $dbFile `
                           -Query "SELECT * FROM Installations WHERE DisplayName NOT IN ($in) ORDER BY TimeLogged DESC"
                } else { $raw = @() }
            } else {
                $raw = @()
            }
        }
    }
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

function FormatRows {
    for ($i=0; $i -lt $grid.Rows.Count; $i++) {
        $row = $grid.Rows[$i]
        $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Black
        switch ($cbFilter.SelectedItem) {
            'New since last run' {
                $ts = [datetime]$row.Cells['TimeLogged'].Value
                if ($ts -gt $lastRun)   { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red }
            }
            'New since last export' {
                $ts = [datetime]$row.Cells['TimeLogged'].Value
                if ($ts -gt $lastExport){ $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red }
            }
            'Unexported (Exported=0)' {
                $exp = [int]$row.Cells['Exported'].Value
                if ($exp -eq 0)         { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red }
            }
            'New since last CSV' {
                $row.DefaultCellStyle.ForeColor = [Drawing.Color]::Red
            }
        }
    }
}

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

# ─────────────────────────────────────────────────────────────────────────────
# 4) Eventhandler: Refresh, Mail und kombinierter Export
# ─────────────────────────────────────────────────────────────────────────────
$btnRef.Add_Click({ LoadData })

$btnMail.Add_Click({
    $new = Invoke-SqliteQuery -DataSource $dbFile `
           -Query "SELECT * FROM Installations WHERE TimeLogged > @lr" `
           -SqlParameters @{ lr = $lastRun.ToString('yyyy-MM-dd HH:mm:ss') }
    if ($new.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show("Keine neuen Installationen seit $lastRun","Info")
        return
    }
    $body = "New installations since $lastRun`r`n"
    $new | ForEach-Object { $body += "$($_.DisplayName) (Installed: $($_.InstallDate))`r`n" }
    try {
        Send-MailMessage -SmtpServer $SmtpServer -Port $SmtpPort `
                         -From $MailFrom -To $MailTo `
                         -Subject "InstallMonitor – new apps since $lastRun" `
                         -Body $body
        [Windows.Forms.MessageBox]::Show("E-Mail gesendet.","Info")
    } catch {
        [Windows.Forms.MessageBox]::Show("Fehler beim Senden:`r`n$($_.Exception.Message)","Fehler")
    }
})

$btnExport.Add_Click({
    $folder = Join-Path $PSScriptRoot 'export'
    New-Item -Path $folder -ItemType Directory -Force | Out-Null

    # Fehler, wenn "New since last CSV" ohne alten Snapshot
    if ($cbFilter.SelectedItem -eq 'New since last CSV') {
        $lastCsv = Get-ChildItem -Path $folder -Filter 'Installations_Export_*.csv' |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
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
    $htmlPath = Join-Path $folder "Installations_$ts.html"

    try {
        # CSV export
        $grid.DataSource | ForEach-Object {
            ($_ | Select-Object * | ConvertTo-Csv -NoTypeInformation) -join "`n"
        } | Set-Content -Encoding UTF8 -Path $csvPath

        # HTML export
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

        # Flags und Timestamp aktualisieren
        Invoke-SqliteQuery -DataSource $dbFile `
          -Query "UPDATE Metadata SET Value = datetime('now') WHERE Key='LastExport';"
        Invoke-SqliteQuery -DataSource $dbFile `
          -Query "UPDATE Installations SET Exported = 1 WHERE Exported = 0;"

        $lastExport = Get-Date
        [Windows.Forms.MessageBox]::Show("Export erfolgreich!`r`n$folder","Export")
        LoadData
    }
    catch {
        [Windows.Forms.MessageBox]::Show("Fehler beim Export:`r`n$($_.Exception.Message)","Fehler")
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# 5) GUI starten
# ─────────────────────────────────────────────────────────────────────────────
$form.Add_Load({ LoadData })
[void]$form.ShowDialog()