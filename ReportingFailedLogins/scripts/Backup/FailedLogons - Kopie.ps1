# SECTION: Load configuration
. "$PSScriptRoot\..\Config-Helper.ps1"

# SECTION: Configuration and paths
$SqliteExe         = Get-SqliteExePath
$DatabaseFile      = Get-DatabasePath -Validate:$false
$EventLogName      = Get-ConfigValue 'EventLogName'
$EventIDs          = @(Get-ConfigValue 'EventIDs')
$DomainControllers = @('ttbvmdc01', 'ttbvmdc02')

Write-Host ""
Write-Host "[INFO] SQLite Executable: $SqliteExe"
Write-Host "[INFO] Database File:     $DatabaseFile"
Write-Host ""

# SECTION: Parameters
$MaxSizeGB     = 500
$EnableStatus  = $true
$VerboseOutput = $false

# SECTION: Backup and database initialization

function Backup-Database {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupPath = "$($DatabaseFile)_backup_$timestamp.db"
    if (Test-Path $DatabaseFile) {
        Copy-Item $DatabaseFile $backupPath -ErrorAction SilentlyContinue
        Write-Host "[WARN] Backup created at $backupPath"
    }
}

function Check-DatabaseSize {
    if (Test-Path $DatabaseFile) {
        $sizeGB = (Get-Item $DatabaseFile).Length / 1GB
        if ($sizeGB -gt $MaxSizeGB) {
            Write-Host "[WARN] Database size exceeds $MaxSizeGB GB ($sizeGB GB)"
            Backup-Database
            Remove-Item $DatabaseFile -Force
            Write-Host "[INFO] Old database removed due to size limit"
        }
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

# Execute setup
Check-DatabaseSize
Initialize-Database

# SECTION: Event parsing and DNS resolution

function Resolve-Hostname {
    param ($ip)
    try {
        $resolved = [System.Net.Dns]::GetHostEntry($ip).HostName
        return $resolved
    } catch {
        return $null
    }
}

# SECTION: Event parsing and DNS resolution

function Resolve-Hostname {
    param ($ip)
    try {
        $resolved = [System.Net.Dns]::GetHostEntry($ip).HostName
        return $resolved
    } catch {
        return $null
    }
}

function Parse-Events {
    param ($events)

    foreach ($event in $events) {
        $xml = [xml]$event.ToXml()
        $data = $xml.Event.EventData.Data

        $props = @{
            EventID                   = $xml.Event.System.EventID.'#text'
            TimeStamp                 = $xml.Event.System.TimeCreated.SystemTime
            SubjectUserSid            = ($data | Where-Object Name -eq 'SubjectUserSid').'#text'
            SubjectUserName           = ($data | Where-Object Name -eq 'SubjectUserName').'#text'
            SubjectDomainName         = ($data | Where-Object Name -eq 'SubjectDomainName').'#text'
            SubjectLogonId            = ($data | Where-Object Name -eq 'SubjectLogonId').'#text'
            LogonType                 = [int]($data | Where-Object Name -eq 'LogonType').'#text'
            LogonTypeName             = $LogonTypeMap[[int]($data | Where-Object Name -eq 'LogonType').'#text']
            TargetUserSid             = ($data | Where-Object Name -eq 'TargetUserSid').'#text'
            TargetUserName            = ($data | Where-Object Name -eq 'TargetUserName').'#text'
            TargetDomainName          = ($data | Where-Object Name -eq 'TargetDomainName').'#text'
            StatusCode                = ($data | Where-Object Name -eq 'Status').'#text'
            SubStatusCode             = ($data | Where-Object Name -eq 'SubStatus').'#text'
            FailureReason             = ($data | Where-Object Name -eq 'FailureReason').'#text'
            WorkstationName           = ($data | Where-Object Name -eq 'WorkstationName').'#text'
            SourceNetworkAddress      = ($data | Where-Object Name -eq 'IpAddress').'#text'
            SourcePort                = [int]($data | Where-Object Name -eq 'Port').'#text'
            ProcessId                 = [int]($data | Where-Object Name -eq 'ProcessId').'#text'
            ProcessName               = ($data | Where-Object Name -eq 'ProcessName').'#text'
            LogonProcessName          = ($data | Where-Object Name -eq 'LogonProcessName').'#text'
            AuthenticationPackageName = ($data | Where-Object Name -eq 'AuthenticationPackageName').'#text'
            TransitedServices         = ($data | Where-Object Name -eq 'TransitedServices').'#text'
            PackageName               = ($data | Where-Object Name -eq 'PackageName').'#text'
            KeyLength                 = [int]($data | Where-Object Name -eq 'KeyLength').'#text'
            ResolvedHost              = Resolve-Hostname (($data | Where-Object Name -eq 'IpAddress').'#text')
            DCSource                  = $env:COMPUTERNAME
            AccountName               = ($data | Where-Object Name -eq 'TargetUserName').'#text'
            FailureDescription        = $StatusMap[($data | Where-Object Name -eq 'Status').'#text']
        }

        $ParsedEvents += New-Object PSObject -Property $props
    }
}

# SECTION: Deduplication and database insertion

function Get-HashString {
    param ($input)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($input)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace "-", "").ToLower()
}

# SECTION: Deduplication and database insertion

function Insert-EventsToDatabase {
    foreach ($event in $ParsedEvents) {
        $exists = & $SqliteExe $DatabaseFile "SELECT COUNT(*) FROM FailedLogons WHERE EventID = $($event.EventID) AND TimeStamp = '$($event.TimeStamp)' AND SubjectUserName = '$($event.SubjectUserName)' AND SourceNetworkAddress = '$($event.SourceNetworkAddress)';"
        
        if ($exists -eq 0) {
            $columns = $event.PSObject.Properties.Name -join ", "
            $values = $event.PSObject.Properties.Value | ForEach-Object {
                if ($_ -is [string]) { "'$($_.Replace("'", "''"))'" } else { $_ }
            } -join ", "

            $query = "INSERT INTO FailedLogons ($columns) VALUES ($values);"
            & $SqliteExe $DatabaseFile $query
            Write-Host "[OK] Inserted event $($event.EventID) at $($event.TimeStamp)"
        } else {
            Write-Host "[SKIP] Duplicate event $($event.EventID) at $($event.TimeStamp)"
        }
    }
}

# SECTION: Main workflow

function Run-FailedLogonCollector {
    Write-Host "[INFO] Starting failed logon collector..."

    $query = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">
      *[System[(EventID=4625)]]
    </Select>
  </Query>
</QueryList>
"@

    try {
        $events = Get-WinEvent -FilterXml $query -ErrorAction Stop
        Write-Host "[INFO] Retrieved $($events.Count) failed logon events"
    } catch {
        Write-Host "[ERROR] Failed to retrieve events: $_"
        return
    }

    $ParsedEvents = @()
    Parse-Events -events $events
    Insert-EventsToDatabase
    Write-Host "[DONE] Processing complete"
}

$EnrichmentScript = ".\Enrichment.ps1"

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