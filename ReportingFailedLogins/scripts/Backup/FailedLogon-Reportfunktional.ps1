# =============================================
# BEGIN: Reporting-Konfig & Initialisierung
# =============================================

# Konfigurationsdatei laden
. "$PSScriptRoot\..\Config-Helper.ps1"

# Pfade und Einstellungen abrufen
$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath

# END: Reporting-Konfig & Initialisierung
# =============================================


# =============================================
# BEGIN: Netzwerk- und Remote-Prüfung
# =============================================

function Test-DomainControllerAccess {
    param([string] $DC)

    Write-Host ""
    Write-Host "Pruefe Verfuegbarkeit von $DC..."

    # Netzwerkcheck (Ping)
    if (-not (Test-Connection -ComputerName $DC -Count 1 -Quiet)) {
        Write-Host "FEHLER: $DC ist per Ping nicht erreichbar."
        return $false
    }
    Write-Host "OK: $DC antwortet auf Ping."

    # WinRM-Check
    try {
        Test-WsMan -ComputerName $DC -ErrorAction Stop
        Write-Host "OK: WinRM ist verfuegbar auf $DC."
    } catch {
        Write-Host "FEHLER: WinRM ist NICHT verfuegbar auf $DC."
        return $false
    }

    # Invoke-Command Test
    try {
        Invoke-Command -ComputerName $DC -ScriptBlock {
            Get-WinEvent -LogName Security -MaxEvents 1 | Select-Object TimeCreated, Id
        } | Out-Null
        Write-Host "OK: Remotezugriff auf EventLog ist moeglich."
        return $true
    } catch {
        Write-Host "FEHLER: Zugriff auf EventLog via Invoke-Command fehlgeschlagen."
        return $false
    }
}

# END: Netzwerk- und Remote-Prüfung
# =============================================


# =============================================
# BEGIN: Event- und Datenbank-Abfrage
# =============================================

function Get-FailedLogonEventCount {
    param(
        [string] $DCName,
        [DateTime] $StartTime = (Get-Date).AddDays(-7)
    )

    $filter = @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $StartTime
    }

    try {
        $events = Get-WinEvent -ComputerName $DCName -FilterHashtable $filter
        return $events.Count
    } catch {
        Write-Host "FEHLER: Eventabfrage fuer $DCName fehlgeschlagen."
        return 0
    }
}

function Get-DBFailedLogonCount {
    param([string] $DCName)

    $query = "SELECT COUNT(*) FROM FailedLogons WHERE DCSource = '$DCName';"
    try {
        $count = & $sqliteExe $dbFile $query
        return [int]$count
    } catch {
        Write-Host "FEHLER: DB-Abfrage fuer $DCName fehlgeschlagen."
        return 0
    }
}

# END: Event- und Datenbank-Abfrage
# =============================================


# =============================================
# BEGIN: Reportausgabe & Ueberschneidungen
# =============================================

function Show-OverlappingEntries {
    param(
        [string] $DC1,
        [string] $DC2
    )

    $query = @"
SELECT AccountName || ' @ ' || TimeStamp AS Entry
FROM FailedLogons
WHERE DCSource = '$DC1'
INTERSECT
SELECT AccountName || ' @ ' || TimeStamp
FROM FailedLogons
WHERE DCSource = '$DC2';
"@

    try {
        $result = & $sqliteExe $dbFile $query
        Write-Host ""
        Write-Host "Pruefe auf gemeinsame Eintraege zwischen $DC1 und $DC2..."
        if ($result.Count -gt 0) {
            Write-Host "Gemeinsame Eintraege gefunden: $($result.Count)"
            $result | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host "Keine Ueberschneidungen vorhanden."
        }
    } catch {
        Write-Host "FEHLER: Ueberschneidungsabfrage fehlgeschlagen."
    }
}

function Show-FailedLogonReport {
    param(
        [string[]] $DCs,
        [DateTime] $StartTime = (Get-Date).AddDays(-1)
    )

    Write-Host ""
    Write-Host "Starte Auswertung von fehlgeschlagenen Logons..."

    foreach ($dc in $DCs) {
        Write-Host ""
        Write-Host "==== $dc ===="

        if (-not (Test-DomainControllerAccess -DC $dc)) {
            Write-Host "Analyse fuer $dc wird uebersprungen."
            continue
        }

        $eventCount = Get-FailedLogonEventCount -DCName $dc -StartTime $StartTime
        $dbCount    = Get-DBFailedLogonCount    -DCName $dc
        $diff       = $eventCount - $dbCount

        Write-Host "Events seit ${StartTime}:        $eventCount"
        Write-Host "Eintraege in Datenbank:       $dbCount"
        Write-Host "Differenz (Log vs. DB):       $diff"
    }

    if ($DCs.Count -ge 2) {
        Show-OverlappingEntries -DC1 $DCs[0] -DC2 $DCs[1]
    }

    Write-Host ""
    Write-Host "Auswertung abgeschlossen."
}

# END: Reportausgabe & Ueberschneidungen
# =============================================


# =============================================
# BEGIN: Hauptausfuehrung
# =============================================

$dcList = @('ttbvmdc01','ttbvmdc02')
Show-FailedLogonReport -DCs $dcList -StartTime (Get-Date).AddDays(-1)

# END: Hauptausfuehrung
# =============================================