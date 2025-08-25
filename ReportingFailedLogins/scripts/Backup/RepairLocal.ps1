# RepairLocal.ps1 - lokale Reparatur von Firewall und Services

param (
    [int]$RetryCount = 3,
    [int]$RetryDelaySeconds = 5
)

function Test-LocalEventLog {
    try {
        Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Repair-FirewallAndServices {
    # Firewall-Regeln fuer Eventlog, RPC, WMI, Dateiserver oeffnen
    $fwKeys = 'Ereignisprotokoll','RPC','WMI','Dateiserver'
    Get-NetFirewallRule -Direction Inbound |
        Where-Object {
            $match = $false
            foreach ($k in $fwKeys) {
                if ($_.DisplayName -match $k) {
                    $match = $true
                    break
                }
            }
            return $match
        } |
        ForEach-Object {
            if (-not $_.Enabled) {
                Enable-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue
            }
        }

    # Services fuer Eventlog, RPC, Registrierungszugriff starten und autostarten
    $svcKeys = 'Ereignisprotokoll','RPC','Registrierung'
    Get-Service |
        Where-Object {
            $match = $false
            foreach ($k in $svcKeys) {
                if ($_.DisplayName -match $k) {
                    $match = $true
                    break
                }
            }
            return $match
        } |
        ForEach-Object {
            Set-Service -Name $_.Name -StartupType Automatic -ErrorAction SilentlyContinue
            if ($_.Status -ne 'Running') {
                Start-Service -Name $_.Name -ErrorAction SilentlyContinue
            }
        }
}

# Hauptlogik
if (Test-LocalEventLog) {
    Write-Host "Eventlog-Lesen OK. Keine Reparatur noetig."
    exit 0
}

Write-Host "Eventlog-Lesen fehlerhaft - starte Reparatur..."
for ($i = 1; $i -le $RetryCount; $i++) {
    Repair-FirewallAndServices
    Start-Sleep -Seconds $RetryDelaySeconds

    if (Test-LocalEventLog) {
        Write-Host "Reparatur erfolgreich nach Versuch $i."
        exit 0
    }
    Write-Host "Versuch $i fehlgeschlagen."
}

Write-Host "Reparatur nach $RetryCount Versuchen fehlgeschlagen."
exit 1