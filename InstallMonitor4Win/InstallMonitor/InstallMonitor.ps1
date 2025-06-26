<#
    InstallMonitor.ps1
    Debug-Version direkt editierbar
#>

param([switch]$SendMail)

# --- Auto-Install & Import PSSQLite ---
try {
    if (-not (Get-Module -ListAvailable -Name PSSQLite)) {
        Write-Host "⋱ PSSQLite nicht gefunden, installiere…" -ForegroundColor Yellow
        Install-Module -Name PSSQLite -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PSSQLite -ErrorAction Stop
    Write-Host "✓ PSSQLite geladen." -ForegroundColor Green
}
catch {
    Write-Host "✗ Fehler PSSQLite: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Variablen & Logs ---
$dbFile = Join-Path $PSScriptRoot 'data\installations.db'
$errLog = Join-Path $PSScriptRoot 'data\installmonitor.log'

if (-not (Test-Path $errLog)) {
    New-Item -Path $errLog -ItemType File -Force | Out-Null
}

function Write-ErrLog { param($m)
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) `t$m" |
      Out-File -Append -Encoding UTF8 -FilePath $errLog
}

# --- Debug: DB anlegen prüfen ---
Write-Host "► Verwende DB-Datei: $dbFile" -ForegroundColor Cyan
if (-not (Test-Path $dbFile)) {
    Write-Host "→ DB nicht gefunden. Erstelle neue DB + Tabellen…" -ForegroundColor Yellow
    Invoke-SqliteQuery -DataSource $dbFile -Query @'
CREATE TABLE Installations(
  Id INTEGER PRIMARY KEY,
  DisplayName TEXT,
  InstallDate TEXT,
  TimeLogged TEXT
);
CREATE TABLE Metadata(
  Key   TEXT PRIMARY KEY,
  Value TEXT
);
'@
    Write-Host "✓ Datenbank erstellt." -ForegroundColor Green
}
else {
    Write-Host "✓ Datenbank existiert bereits." -ForegroundColor Green
}

# --- Programme scannen ---
function Get-InstalledApps {
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' |
    ForEach-Object {
        Get-ItemProperty $_ | Where-Object DisplayName |
        Select-Object DisplayName, InstallDate
    }
}

$apps    = Get-InstalledApps
$newApps = [System.Collections.Generic.List[psobject]]::new()

# --- Neue Installs ermitteln & speichern ---
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
foreach ($a in $apps) {
    $cnt = Invoke-SqliteQuery -DataSource $dbFile `
        -Query "SELECT COUNT(*) AS C FROM Installations WHERE DisplayName=@n;" `
        -SqlParameters @{n=$a.DisplayName}
    if ($cnt.C -eq 0) {
        Invoke-SqliteQuery -DataSource $dbFile `
          -Query "INSERT INTO Installations(DisplayName,InstallDate,TimeLogged) VALUES(@n,@d,@t);" `
          -SqlParameters @{n=$a.DisplayName; d=$a.InstallDate; t=$now}
        $newApps.Add([pscustomobject]@{
            DisplayName = $a.DisplayName
            InstallDate = $a.InstallDate
            TimeLogged  = $now
        })
    }
}

# letzten Lauf lesen für Betreff
$lastRec = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT Value FROM Metadata WHERE Key='LastRun';"
$lastRun = if ($lastRec) { $lastRec.Value } else { '1970-01-01 00:00:00' }

# --- Mail-Versand (Debug) ---
# feste SMTP-Parameter
$SmtpServer = '172.16.30.21'
$SmtpPort   = 25
$MailFrom   = 'monitor@technoteam.de'
$MailTo     = 'thomas.schmidt@technoteam.de'

if ($SendMail -and $newApps.Count -gt 0) {
    # Body zusammenstellen
    $body = "New installations since $lastRun`r`n"
    $newApps | ForEach-Object {
        $body += "$($_.DisplayName) (Installed: $($_.InstallDate))`r`n"
    }

    # Debug-Ausgaben
    Write-Host "`n► Mail-Konfiguration" -ForegroundColor Cyan
    Write-Host "   Server: ${SmtpServer}:${SmtpPort}" -ForegroundColor Cyan 
    Write-Host "   From  : ${MailFrom}" -ForegroundColor Cyan
    Write-Host "   To    : ${MailTo}" -ForegroundColor Cyan
    Write-Host "   Body  :`${n$body}" -ForegroundColor DarkGray

    # Test Verbindung
    $t = Test-NetConnection -ComputerName $SmtpServer -Port $SmtpPort
    Write-Host "   TCP erreichbar? $($t.TcpTestSucceeded)" -ForegroundColor Cyan

    # Send-MailMessage
    try {
        Send-MailMessage `
          -SmtpServer $SmtpServer -Port $SmtpPort `
          -From $MailFrom -To $MailTo `
          -Subject "InstallMonitor – new apps since $lastRun" `
          -Body $body -Verbose
        Write-Host "✓ Mail gesendet (Send-MailMessage ohne Fehler)." -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Fehler beim Mailen: $($_.Exception.Message)" -ForegroundColor Red
        Write-ErrLog "Mail-Error: $($_.Exception.Message)"
    }
}

# --- LastRun aktualisieren ---
Invoke-SqliteQuery -DataSource $dbFile `
  -Query "INSERT OR REPLACE INTO Metadata(Key,Value) VALUES('LastRun',@t);" `
  -SqlParameters @{t=$now}