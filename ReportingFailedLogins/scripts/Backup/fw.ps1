# Aktiviert wichtige Firewallregeln für RPC/DCOM-Zugriffe

$rpcRules = @(
    "COM+-Netzwerkzugriff (DCOM-In)",
    "COM+-Remoteverwaltung (DCOM-In)"
)

foreach ($rule in $rpcRules) {
    try {
        Write-Host "Aktiviere Regel: $rule"
        Enable-NetFirewallRule -DisplayName $rule
    } catch {
        Write-Warning "Regel '$rule' konnte nicht aktiviert werden: $_"
    }
}

Write-Host "`n🟢 Alle definierten Regeln wurden verarbeitet."