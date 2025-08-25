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

Invoke-Command -ComputerName ttbvmdc01, ttbvmdc02 -ScriptBlock { "$env:COMPUTERNAME`: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }

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

# 🔍 NEU: Schneller Eventlog-Test auf mindestens 1 Event
function Test-EventLogPresence {
    param ([string]$DC)

    Write-Host "Teste Beispielabruf von 4625-Events auf $DC..."

    try {
        $result = Invoke-Command -ComputerName $DC -ScriptBlock {
            Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 1 |
            Select-Object TimeCreated
        }
        if ($result) {
            Write-Host "OK: Mindestens ein 4625-Event vorhanden. Beispielzeit: $($result.TimeCreated)"
            return $true
        } else {
            Write-Host "WARNUNG: Keine 4625-Events gefunden."
            return $false
        }
    } catch {
        Write-Host "FEHLER: Abruf des Events via Invoke-Command fehlgeschlagen."
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

    switch ($DCName) {
        'ttbvmdc01' {
            Write-Host "Verwende WMI-Methode für $DCName"
            return Get-FailedLogonEventCountWMI -DCName $DCName -StartTime $StartTime
        }
        default {
            Write-Host "Verwende Standardmethode fuer $DCName"
            $filter = @{
                LogName   = 'Security'
                Id        = 4625
                StartTime = $StartTime
            }

            try {
                $events = Get-WinEvent -ComputerName $DCName -FilterHashtable $filter
                return $events.Count
            } catch {
                Write-Host "FEHLER: Eventabfrage via Get-WinEvent fuer $DCName fehlgeschlagen."
                return 0
            }
        }
    }
}

function Get-FailedLogonEventCountWMI {
    param(
        [string] $DCName,
        [DateTime] $StartTime = (Get-Date).AddDays(-7)
    )

    try {
        $events = Invoke-Command -ComputerName $DCName -ScriptBlock {
            param ($pStartUTC)
            
            Get-WmiObject -Class Win32_NTLogEvent -Filter "Logfile='Security' AND EventCode=4625" |
            Where-Object {
                ([System.Management.ManagementDateTimeConverter]::ToDateTime($_.TimeGenerated) -gt $pStartUTC)
            } |
            Select-Object TimeGenerated -First 500
        } -ArgumentList $StartTime

        return $events.Count
    } catch {
        Write-Host "FEHLER: WMI-Abfrage für $DCName fehlgeschlagen."
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

# =============================================
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

        # 👁️ NEU: 4625-Probe-Abruf
        Test-EventLogPresence -DC $dc

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