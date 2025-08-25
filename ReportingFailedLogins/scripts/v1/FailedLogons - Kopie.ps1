# FailedLogons.ps1
# SECTION: Load configuration
. "$PSScriptRoot\..\Config-Helper.ps1"

# SECTION: Configuration and paths
$SqliteExe         = Get-SqliteExePath
$DatabaseFile    = Get-DatabasePath -Validate:$false
$MetaDataFile    = Get-DatabasePath -Validate:$false  # separat, editierbar
$EventLogName      = Get-ConfigValue 'EventLogName'
$EventIDs          = @(Get-ConfigValue 'EventIDs')
$DomainControllers = @('ttbvmdc01', 'ttbvmdc02')
$EnrichmentScript  = "$PSScriptRoot\Enrichment.ps1"

Write-Host ""
Write-Host "[INFO] SQLite Executable: $SqliteExe"
Write-Host "[INFO] Database File:     $DatabaseFile"
Write-Host ""

# SECTION: Backup and database initialization
function Backup-Database {
    if (Test-Path $DatabaseFile) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupFile = "$DatabaseFile.bak_$timestamp"
        Copy-Item $DatabaseFile $backupFile
        Write-Host "[INFO] Backup created: $backupFile"
    }
}

function Initialize-Database {
    if (-not (Test-Path $DatabaseFile)) {
        Write-Host "[INFO] Creating new database schema..."

        $schema = @"
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
    DCSource                  TEXT,
    AccountName               TEXT,
    FailureDescription        TEXT,
    SubFailureDescription     TEXT,
    FailureReasonDescription  TEXT,
    UNIQUE(EventID, TimeStamp, SubjectUserName, SourceNetworkAddress)
);

CREATE INDEX IF NOT EXISTS idx_TimeStamp ON FailedLogons(TimeStamp);
CREATE INDEX IF NOT EXISTS idx_TargetUserName ON FailedLogons(TargetUserName);
CREATE INDEX IF NOT EXISTS idx_SourceNetworkAddress ON FailedLogons(SourceNetworkAddress);
"@

        try {
            $schema | & $SqliteExe $DatabaseFile
            Write-Host "[OK] Database initialized"
        } catch {
            Write-Host "[ERROR] Failed to initialize database: $_"
        }
    } else {
        Write-Host "[INFO] Database already exists"
    }
}

# SECTION: Event collection
function Get-FailedLogonEvents {
    $allEvents = @()

    foreach ($dc in $DomainControllers) {
        Write-Host "[INFO] Querying $EventLogName on $dc..."

        try {
            $events = Get-WinEvent -ComputerName $dc -FilterHashtable @{LogName=$EventLogName; Id=$EventIDs}
            Write-Host "[INFO] Found $($events.Count) events on $dc"
            $allEvents += $events
        } catch {
            Write-Host "[ERROR] Failed to query ${dc}: $_"
        }
    }

    Write-Host "[INFO] Total collected events: $($allEvents.Count)"
    return $allEvents
}

# SECTION: XML field extraction helper
function Get-EventField {
    param ($xml, $fieldName)
    return ($xml.Event.EventData.Data | Where-Object { $_.Name -eq $fieldName }).'#text'
}

# SECTION: Deduplication and database insertion
function Add-EventsToDatabase {
    param ($events)

    foreach ($evt in $events) {
        $xml = [xml]$evt.ToXml()

        $logonType = [int](Get-EventField $xml 'LogonType')

        $data = @{
            EventID                   = $evt.Id
            TimeStamp                 = $evt.TimeCreated.ToString("s")
            SubjectUserSid            = Get-EventField $xml 'SubjectUserSid'
            SubjectUserName           = Get-EventField $xml 'SubjectUserName'
            SubjectDomainName         = Get-EventField $xml 'SubjectDomainName'
            SubjectLogonId            = Get-EventField $xml 'SubjectLogonId'
            LogonType                 = $logonType
            LogonTypeName             = ""
            TargetUserSid             = Get-EventField $xml 'TargetUserSid'
            TargetUserName            = Get-EventField $xml 'TargetUserName'
            TargetDomainName          = Get-EventField $xml 'TargetDomainName'
            StatusCode                = Get-EventField $xml 'Status'
            SubStatusCode             = Get-EventField $xml 'SubStatus'
            FailureReason             = Get-EventField $xml 'FailureReason'
            WorkstationName           = Get-EventField $xml 'WorkstationName'
            SourceNetworkAddress      = Get-EventField $xml 'IpAddress'
            SourcePort                = [int](Get-EventField $xml 'Port')
            ProcessId                 = [int](Get-EventField $xml 'ProcessId')
            ProcessName               = Get-EventField $xml 'ProcessName'
            LogonProcessName          = Get-EventField $xml 'LogonProcessName'
            AuthenticationPackageName = Get-EventField $xml 'AuthenticationPackageName'
            TransitedServices         = Get-EventField $xml 'TransitedServices'
            PackageName               = Get-EventField $xml 'PackageName'
            KeyLength                 = [int](Get-EventField $xml 'KeyLength')
            ResolvedHost              = ""
            DCSource                  = $env:COMPUTERNAME
            AccountName               = Get-EventField $xml 'TargetUserName'
            FailureDescription        = ""
            SubFailureDescription     = ""
            FailureReasonDescription   = ""
        }

        $columns = ($data.Keys -join ", ")
        $values  = ($data.Values | ForEach-Object { "'$_'" }) -join ", "
        $sql     = "INSERT OR IGNORE INTO FailedLogons ($columns) VALUES ($values);"

        try {
            $sql | & $SqliteExe $DatabaseFile
        } catch {
            Write-Host "[ERROR] Failed to insert event: $_"
        }
    }

    Write-Host "[OK] Inserted $($events.Count) events into database"
}

# SECTION: Enrichment
function Invoke-EnrichmentProcess {
    if (Test-Path $EnrichmentScript) {
        Write-Host "[INFO] Enrichment script found - executing $EnrichmentScript"
        try {
            & $EnrichmentScript
            Write-Host "[OK] Enrichment completed"
        } catch {
            Write-Host "[ERROR] Enrichment script failed: $_"
        }
    } else {
        Write-Host "[INFO] No enrichment script found - skipping post-processing"
    }
}

# SECTION: Update Meta
$MetaPath = Join-Path (Split-Path $MetaDataFile) 'reportmeta.json'
$meta     = Load-Meta -Path $MetaPath
$meta.LastFailedLogonScan = (Get-Date).ToString("s")
$meta.FailedEventCount    = $events.Count
Save-Meta $meta -Path $MetaPath

Write-Host "[INFO] Meta updated - Events: $($events.Count), Timestamp: $($meta.LastFailedLogonScan)"

# SECTION: Main workflow
Backup-Database
Initialize-Database
$events = Get-FailedLogonEvents
if ($events.Count -gt 0) {
    Add-EventsToDatabase -events $events
} else {
    Write-Host "[INFO] No events to process"
}
Invoke-EnrichmentProcess