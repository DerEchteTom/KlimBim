<# 
    send.ps1
    - Startet sich bei Bedarf mit Adminrechten neu (nur wenn Freigabe fehlt)
    - Setzt ExecutionPolicy nur fuer diesen Prozess
    - Erstellt Reportverzeichnis und prueft SMB-Freigabe
#>

param(
    [switch]$Elevated,
    [string]$To         = 'user@domain.de',
    [string]$From       = 'noreply@domain.de',
    [string]$SmtpServer = '1xx.xxx.xxx.xxx',
    [int]$SmtpPort      = 25
)

function Test-Admin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Restart-AsAdmin {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) {
        Write-Warning "Skriptpfad konnte nicht ermittelt werden. Neustart abgebrochen."
        exit 1
    }

    $scriptDir = Split-Path -Path $scriptPath -Parent
    $exe       = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $isConsole = ($Host.Name -eq 'ConsoleHost')

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if (-not $isConsole) { $argList += '-NoExit' }
    $argList += @('-File', "`"$scriptPath`"", '-Elevated')

    try {
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList -WorkingDirectory $scriptDir -WindowStyle Normal
        Write-Host "Skript wird mit Adminrechten neu gestartet..."
    } catch {
        Write-Host "Fehler beim Neustart: $($_.Exception.Message)"
    }
    exit
}

function Prompt-ForElevation {
    Write-Host ""
    Write-Host "Freigabe fehlt und Adminrechte sind erforderlich."
    Write-Host "Skript im Admin-Modus neu starten?"
    Write-Host "Druecke [J] fuer Ja, [N] fuer Nein - Timeout in 10 Sekunden..."

    $choice = $null
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    while ($timer.Elapsed.TotalSeconds -lt 10 -and -not $choice) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey(
                [System.Management.Automation.Host.ReadKeyOptions]::NoEcho -bor
                [System.Management.Automation.Host.ReadKeyOptions]::IncludeKeyDown
            )
            $char = $key.Character.ToString().ToLower()

            switch ($char) {
                'j' { $choice = 'ja' }
                'n' { $choice = 'nein' }
                default {
                    Write-Host "Ungueltige Eingabe: '$char'. Bitte J oder N druecken."
                }
            }
        }
        Start-Sleep -Milliseconds 200
    }

    if (-not $choice) {
        Write-Host ""
        Write-Host "Timeout erreicht. Standardaktion: Skript wird nicht neu gestartet."
        $choice = 'nein'
    }

    if ($choice -eq 'ja') {
        Write-Host "Neustart im Admin-Modus..."
        Restart-AsAdmin
    } else {
        Write-Host "Keine Adminrechte. Freigabe kann nicht erstellt werden."
        exit
    }
}
function Ensure-ReportShare {
    param (
        [string]$ShareName,
        [string]$LocalPath
    )

    if (-not (Test-Path $LocalPath)) {
        Write-Host "Verzeichnis existiert nicht - erstelle..."
        New-Item -Path $LocalPath -ItemType Directory | Out-Null
    }

    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

    if ($existingShare) {
        if ($existingShare.Path -ne $LocalPath) {
            Write-Warning "Freigabe '$ShareName' zeigt auf einen anderen Pfad!"
            if (-not (Test-Admin)) {
                Prompt-ForElevation
            }
            Remove-SmbShare -Name $ShareName -Force
            $existingShare = $null
        } else {
            Write-Host "Freigabe '$ShareName' ist korrekt eingerichtet."
        }
    }

    if (-not $existingShare) {
        $uncPath = "\\$env:COMPUTERNAME\$ShareName"
        if (-not (Test-Path $uncPath)) {
            Write-Host "Freigabe '$ShareName' nicht vorhanden - Adminrechte notwendig zur Erstellung."
            if (-not (Test-Admin)) {
                Prompt-ForElevation
            }
        }

        try {
            New-SmbShare -Name $ShareName -Path $LocalPath -Description "Reportfreigabe"
            Grant-SmbShareAccess -Name $ShareName -AccountName '*S-1-1-0' -AccessRight Full -Force
            Write-Host "Freigabe '$ShareName' erfolgreich erstellt."
        } catch {
            Write-Host "Fehler beim Erstellen der Freigabe: $($_.Exception.Message)"
            exit 1
        }
    }
}

try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
} catch {
    Write-Host "Konnte Execution Policy nicht setzen: $($_.Exception.Message)"
}

$shareName      = 'report'
$reportDirLocal = Join-Path $PSScriptRoot $shareName
Write-Host "Lokales Report-Verzeichnis: $reportDirLocal"

Ensure-ReportShare -ShareName $shareName -LocalPath $reportDirLocal

Write-Host "Suche neuesten Report..."
$latestReport = Get-ChildItem -Path $reportDirLocal -Filter 'report_*.html' |
    Where-Object { $_.Name -notmatch '_diff\.html$' } |
    Sort-Object Name -Descending |
    Select-Object -First 1

Write-Host "Suche neuesten Diff-Report..."
$latestDiff = Get-ChildItem -Path $reportDirLocal -Filter 'report_*_diff.html' |
    Sort-Object Name -Descending |
    Select-Object -First 1

if (-not $latestReport) {
    Write-Host "Keine normale Report-Datei gefunden."
    exit 1
}
if (-not $latestDiff) {
    Write-Host "Keine Diff-Report-Datei gefunden."
    exit 1
}

Write-Host "Neuester Report: $($latestReport.Name)"
Write-Host "Neuester Diff:   $($latestDiff.Name)"

$hostname  = $env:COMPUTERNAME
$uncReport = "\\$hostname\$shareName\$($latestReport.Name)"
$uncDiff   = "\\$hostname\$shareName\$($latestDiff.Name)"

Write-Host "UNC Report: $uncReport"
Write-Host "UNC Diff:   $uncDiff"

if ($latestReport.Name -match '^report_(\d{4})(\d{2})(\d{2})_(\d{4})\.html$') {
    $dateObj = Get-Date ("$($matches[1])-$($matches[2])-$($matches[3])")
} else {
    $dateObj = Get-Date
}
$subject = "Install Report - {0:yyyy-MM-dd}" -f $dateObj
Write-Host "Betreff: $subject"

$body = @"
<html>
<body>
    <p>Guten Tag,</p>
    <p>hier die aktuellen Report-Links:</p>
    <ul>
        <li><a href="file:///$uncReport">$($latestReport.Name)</a></li>
        <li><a href="file:///$uncDiff">$($latestDiff.Name)</a></li>
    </ul>
    <p>Viele Gruesse<br/>Ihr Installations-Report-System</p>
</body>
</html>
"@

Write-Host "Sende E-Mail an $To ueber SMTP-Server $SmtpServer..."

try {
    Send-MailMessage `
        -From       $From `
        -To         $To `
        -Subject    $subject `
        -Body       $body `
        -BodyAsHtml `
        -SmtpServer $SmtpServer `
        -Port       $SmtpPort `
        -Encoding   ([System.Text.Encoding]::UTF8)

    Write-Host "E-Mail erfolgreich verschickt."
} catch {
    Write-Host "E-Mail-Versand fehlgeschlagen: $($_.Exception.Message)"
}

Write-Host "`nFertig. Dieses Script schliesst sich in 30 Sekunden..."
Start-Sleep -Seconds 30