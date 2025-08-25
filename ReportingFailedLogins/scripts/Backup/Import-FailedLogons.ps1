<#
.SYNOPSIS
  Imports failed logon attempts (Event ID 4625) into a SQLite database "FailedLogons".
#>

# Load configuration helpers
. "$PSScriptRoot\..\Config-Helper.ps1"

# Initial setup
$sqliteExe     = Get-SqliteExePath
$dbPath        = Get-DatabasePath
$excludedUsers = Get-ExcludedUsers
$fields        = Get-FieldsConfig
$logDir        = "$PSScriptRoot\..\log"
if (!(Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }
$logFile       = Join-Path $logDir "Import-FailedLogons.log"

# Helper: write to logfile with colored console output
function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp [$Level] $Message"
    Add-Content -Path $logFile -Value $line

    switch ($Level) {
        "ERROR" { Write-Host "ERROR: $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "WARN:  $Message" -ForegroundColor Yellow }
        default { Write-Host "INFO:  $Message" -ForegroundColor Cyan }
    }
}

Write-Log "Starting import for Event ID 4625..."

# Mapping of LogonType IDs to readable names
$logonTypeMap = @{
    0  = 'System'; 2 = 'Interactive'; 3 = 'Network'; 4 = 'Batch'; 5 = 'Service'; 7 = 'Unlock';
    8  = 'NetworkCleartext'; 9 = 'NewCredentials'; 10 = 'RemoteInteractive'; 11 = 'CachedInteractive';
    12 = 'CachedRemoteInteractive'; 13 = 'CachedUnlock'
}

# Mapping of Status/Reason codes
$statusMap = @{
    '0xC000006D' = 'Logon failed'
    '0xC000006A' = 'Wrong password'
    '0xC0000064' = 'User does not exist'
    '0xC0000234' = 'Account locked out'
    '0xC0000070' = 'Logon time restriction'
    '0xC0000071' = 'Password expired'
    '0xC0000133' = 'Clock skew'
    '0xC0000225' = 'Unknown user name'
    '0xC000015B' = 'Not allowed to logon'
}

# Create DB structure if missing
if (!(Test-Path $dbPath)) {
    Write-Log "SQLite database will be created: $dbPath" "WARN"

    $sqlCreate = @"
CREATE TABLE IF NOT EXISTS FailedLogons (
    Id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    EventID                   INTEGER,
    TimeStamp                 TEXT,
    SubjectUserSid            TEXT,
    SubjectUserName           TEXT,
    SubjectDomainName         TEXT,
    SubjectLogonId            TEXT,
    LogonType                 INTEGER,
    LogonTypeName             TEXT,
    TargetUserSid             TEXT,
    TargetUserName            TEXT,
    TargetDomainName          TEXT,
    StatusCode                TEXT,
    SubStatusCode             TEXT,
    FailureReason             TEXT,
    WorkstationName           TEXT,
    SourceNetworkAddress      TEXT,
    SourcePort                INTEGER,
    ProcessId                 INTEGER,
    ProcessName               TEXT,
    LogonProcessName          TEXT,
    AuthenticationPackageName TEXT,
    TransitedServices         TEXT,
    PackageName               TEXT,
    KeyLength                 INTEGER,
    ResolvedHost              TEXT,
    UNIQUE(EventID, TimeStamp, SubjectUserName, SourceNetworkAddress)
);
"@
    $sqlCreate | & $sqliteExe $dbPath
    Write-Log "Database structure initialized."
}

# -------------------------------------------------------
# ⏳ TIME FILTER SECTION: Switch between test or regular run
# -------------------------------------------------------
$isTestMode = $false  # ← Set to $true for time-range based import

if ($isTestMode) {
    # Test mode active — manually set time window for test data
    $start = (Get-Date).AddHours(-2)
    $end   = Get-Date
    Write-Log "Test mode: Fetching events from $start to $end"

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $start
        EndTime   = $end
    }

    Write-Log "Found test-mode events: $($events.Count)"
}
else {
    # Normal mode — get latest timestamp from database
    $query = "SELECT MAX(TimeStamp) FROM FailedLogons;"
    $lastTimeStr = & $sqliteExe $dbPath $query
    $lastTime = if ($lastTimeStr) { [datetime]::Parse($lastTimeStr).AddSeconds(1) } else { (Get-Date).AddDays(-7) }
    Write-Log "Reading Event Log from timestamp: $lastTime"

    $events = Get-WinEvent -FilterHashtable @{
        LogName   = 'Security'
        Id        = 4625
        StartTime = $lastTime
    } -MaxEvents 5000

    Write-Log "Found new events: $($events.Count)"
}

# -------------------------------------------------------
# 🔄 EVENT PARSING AND DATABASE INSERTION
# -------------------------------------------------------
foreach ($event in $events) {
    try {
        # Convert event XML to extract fields
        $xml = [xml]$event.ToXml()
        $data = $xml.Event.EventData.Data
        $dict = @{}
        foreach ($d in $data) { $dict[$d.Name] = $d.'#text' }

        # Skip excluded usernames
        if ($excludedUsers -contains $dict["SubjectUserName"]) {
            Write-Log "Skipped excluded user: '$($dict["SubjectUserName"])'"
            continue
        }

        # Map values from event to database fields
        $timestamp     = $xml.Event.System.TimeCreated.SystemTime
        $eventID       = $xml.Event.System.EventID
        $logonType     = [int]$dict["LogonType"]
        $logonTypeName = $logonTypeMap[$logonType]
        $status        = $dict["Status"]
        $subStatus     = $dict["SubStatus"]
        $failure       = "$($statusMap[$status]) / $($statusMap[$subStatus])"
        $ip            = $dict["IpAddress"]
        $resolvedHost  = ""

        # Resolve hostname from IP (if available and not localhost)
        if ($ip -and ($ip -notmatch "^::" -and $ip -ne "127.0.0.1")) {
            try {
                $resolvedHost = (Resolve-DnsName -Name $ip -ErrorAction SilentlyContinue).NameHost
            } catch {
                Write-Log "DNS resolution failed for IP: $ip" "WARN"
            }
        }

        # Prepare SQL INSERT with all required fields
        $sqlInsert = @"
INSERT OR IGNORE INTO FailedLogons (
    EventID, TimeStamp, SubjectUserSid, SubjectUserName, SubjectDomainName, SubjectLogonId,
    LogonType, LogonTypeName, TargetUserSid, TargetUserName, TargetDomainName,
    StatusCode, SubStatusCode, FailureReason, WorkstationName, SourceNetworkAddress,
    SourcePort, ProcessId, ProcessName, LogonProcessName, AuthenticationPackageName,
    TransitedServices, PackageName, KeyLength, ResolvedHost
) VALUES (
    $eventID, '$timestamp', '$($dict["SubjectUserSid"])', '$($dict["SubjectUserName"])', '$($dict["SubjectDomainName"])', '$($dict["SubjectLogonId"])',
    $logonType, '$logonTypeName', '$($dict["TargetUserSid"])', '$($dict["TargetUserName"])', '$($dict["TargetDomainName"])',
    '$status', '$subStatus', '$failure', '$($dict["WorkstationName"])', '$ip',
    $($dict["IpPort"]), $($dict["ProcessId"]), '$($dict["ProcessName"])', '$($dict["LogonProcessName"])', '$($dict["AuthenticationPackageName"])',
    '$($dict["TransmittedServices"])', '$($dict["PackageName"])', $($dict["KeyLength"]), '$resolvedHost'
);
"@

        # Execute SQL INSERT
        $sqlInsert | & $sqliteExe $dbPath
        Write-Log "Event imported: ID $eventID at $timestamp"
    }
    catch {
        Write-Log "Error processing event: $_" "ERROR"
    }
}

Write-Log "Import completed."