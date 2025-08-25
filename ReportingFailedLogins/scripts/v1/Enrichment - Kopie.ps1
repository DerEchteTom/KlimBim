# SECTION: Load configuration
. "$PSScriptRoot\..\Config-Helper.ps1"
$SqliteExe    = Get-SqliteExePath
$DatabaseFile = Get-DatabasePath -Validate:$false

# SECTION: Debugging toggle
$EnableDebugOutput = $false  # auf $false setzen, um CLI-Ausgabe zu reduzieren

function Write-DebugInfo {
    param ($msg)
    if ($EnableDebugOutput) {
        Write-Host $msg
    }
}

# SECTION: LogonType mapping
function Get-LogonTypeName {
    param ([int]$Type)
    switch ($Type) {
        2  { return 'Interactive' }
        3  { return 'Network' }
        4  { return 'Batch' }
        5  { return 'Service' }
        7  { return 'Unlock' }
        8  { return 'NetworkCleartext' }
        9  { return 'NewCredentials' }
        10 { return 'RemoteInteractive' }
        11 { return 'CachedInteractive' }
        default { return 'Unknown' }
    }
}

# SECTION: Mapping tables
$StatusMap = @{
    '0XC000006D' = 'Anmeldung fehlgeschlagen'
    '0XC000006E' = 'Unbekannter Benutzername'
    '0XC000006F' = 'Kennwort abgelaufen'
    # Weitere Statuscodes nach Bedarf
}

$SubStatusMap = @{
    '0XC0000064' = 'Benutzername nicht gefunden'
    '0XC000006A' = 'Ungueltiges Kennwort'
    '0XC0000070' = 'Zeitbeschränkung'
    # Weitere SubStatuscodes nach Bedarf
}

$FailureReasonMap = @{
    '%%2313' = 'Unbekannter Benutzername oder ungueltiges Kennwort'
    '%%2312' = 'Konto derzeit deaktiviert'
    '%%2310' = 'Konto gesperrt'
    '%%2304' = 'Benutzerkonto abgelaufen'
    '%%2303' = 'Zeitbeschränkung'
    # Weitere Codes nach Bedarf
}

# SECTION: Helper for safe SQL strings
function ConvertTo-SafeSqlString {
    param ($text)
    return $text -replace "'", "''"
}

# SECTION: Hostname resolution (dummy fallback)
function Resolve-Hostname {
    param ($ip)
    if ([string]::IsNullOrWhiteSpace($ip)) { return $null }
    try {
        $resolved = [System.Net.Dns]::GetHostEntry($ip).HostName
        return $resolved
    } catch {
        return $null
    }
}

# SECTION: Enrichment process
Write-Host "[INFO] Starting enrichment process..."

$query = @"
SELECT Id, SourceNetworkAddress, StatusCode, SubStatusCode, LogonType, FailureReason
FROM FailedLogons
WHERE ResolvedHost IS NULL OR ResolvedHost = ''
   OR FailureDescription IS NULL OR FailureDescription = ''
   OR SubFailureDescription IS NULL OR SubFailureDescription = ''
   OR LogonTypeName IS NULL OR LogonTypeName = ''
   OR FailureReasonDescription IS NULL OR FailureReasonDescription = '';
"@

# Use correct separator for parsing
$rows = & $SqliteExe -separator "|" $DatabaseFile $query

if (-not $rows) {
    Write-Host "[INFO] Keine Zeilen zur Verarbeitung gefunden."
    Write-Host "[DONE] Enrichment completed"
    return
}

Write-Host "[INFO] Anzahl zu verarbeitender Zeilen: $($rows.Count)"

foreach ($row in $rows) {
    $parts = $row -split '\|'
    if ($parts.Count -lt 6) {
        Write-DebugInfo "[WARN] Ungültige Zeile: $row"
        continue
    }

    $id              = $parts[0]
    $ip              = $parts[1]
    $statusCode      = $parts[2].Trim().ToUpper()
    $subStatusCode   = $parts[3].Trim().ToUpper()
    $logonTypeRaw    = $parts[4].Trim()
    $failureReason   = $parts[5].Trim()

    $logonType = 0
    if (-not [int]::TryParse($logonTypeRaw, [ref]$logonType)) {
        $logonTypeName = $null
    } else {
        $logonTypeName = Get-LogonTypeName $logonType
    }

    $resolved        = Resolve-Hostname $ip
    $statusDesc      = $StatusMap[$statusCode]
    $subDesc         = $SubStatusMap[$subStatusCode]
    $failureDesc     = $FailureReasonMap[$failureReason]

    $resolvedSql     = if ($resolved) { "'" + (ConvertTo-SafeSqlString $resolved) + "'" } else { "NULL" }
    $descSql         = if ($statusDesc) { "'" + (ConvertTo-SafeSqlString $statusDesc) + "'" } else { "NULL" }
    $subDescSql      = if ($subDesc) { "'" + (ConvertTo-SafeSqlString $subDesc) + "'" } else { "NULL" }
    $logonSql        = if ($logonTypeName -and $logonTypeName -ne 'Unknown') { "'" + (ConvertTo-SafeSqlString $logonTypeName) + "'" } else { "NULL" }
    $failureSql      = if ($failureDesc) { "'" + (ConvertTo-SafeSqlString $failureDesc) + "'" } else { "NULL" }

    $updateQuery = "UPDATE FailedLogons SET ResolvedHost = $resolvedSql, FailureDescription = $descSql, SubFailureDescription = $subDescSql, LogonTypeName = $logonSql, FailureReasonDescription = $failureSql WHERE Id = $id;"
    $result = & $SqliteExe $DatabaseFile $updateQuery

    Write-DebugInfo "[INFO] ID=$id | IP=$ip | Host=$resolved | Status=$statusCode → $statusDesc | SubStatus=$subStatusCode → $subDesc | LogonType=$logonTypeRaw → $logonTypeName | FailureReason=$failureReason → $failureDesc"
    Write-DebugInfo "[SQL] $updateQuery"
    Write-DebugInfo "[RESULT] $result"
}

Write-Host "[DONE] Enrichment completed"