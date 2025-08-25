<#
.SYNOPSIS
  Imports failed logon events from Domain Controllers into an SQLite database.
.VERSION
  2.6.0
#>

Set-StrictMode -Version Latest

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

# SECTION: Expected columns for schema validation
$ExpectedFailedLogonsColumns = @(
    'Id','EventID','TimeStamp','SubjectUserSid','SubjectUserName',
    'SubjectDomainName','SubjectLogonId','LogonType','LogonTypeName',
    'TargetUserSid','TargetUserName','TargetDomainName','StatusCode',
    'SubStatusCode','FailureReason','WorkstationName','SourceNetworkAddress',
    'SourcePort','ProcessId','ProcessName','LogonProcessName',
    'AuthenticationPackageName','TransitedServices','PackageName',
    'KeyLength','ResolvedHost','DCSource','AccountName','FailureDescription'
)

# SECTION: Host resolution
function Get-ResolvedHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IpAddress
    )

    try {
        $dns = Resolve-DnsName -Name $IpAddress -ErrorAction Stop |
               Select-Object -First 1 -ExpandProperty NameHost
        return $dns
    }
    catch {
        return $IpAddress
    }
}

# SECTION: Database creation and schema validation
function New-Database {
    Write-Host "[INFO] Creating or verifying database structure..."

    if (Test-Path $DatabaseFile) {
        # Prüfe bestehendes Schema auf fehlende Spalten
        $actualCols = & $SqliteExe $DatabaseFile "PRAGMA table_info(FailedLogons);" |
                      ForEach-Object { ($_ -split '\|')[1].Trim() }

        $missing = @(
            $ExpectedFailedLogonsColumns |
            Where-Object { $_ -notin $actualCols }
        )

        if ($missing.Count -gt 0) {
            Write-Warning "[WARNING] Schema mismatch detected. Missing columns: $($missing -join ', ')"
            $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backupPath = "$DatabaseFile.$timestamp.bak"
            Copy-Item $DatabaseFile $backupPath -Force
            Write-Host "[INFO] Backup created at: $backupPath"
            Remove-Item $DatabaseFile -Force
            Write-Host "[INFO] Old database removed. Reinitializing..."
            New-Item -ItemType File -Path $DatabaseFile -Force | Out-Null
        }
        else {
            Write-Host "[INFO] Existing database schema is complete."
        }
    }
    else {
        Write-Host "[INFO] Database file does not exist. Creating new file..."
        New-Item -ItemType File -Path $DatabaseFile -Force | Out-Null
    }

    # Create table with full schema
    $CreateScript = @"
PRAGMA user_version = 1;
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
"@

    try {
        & $SqliteExe $DatabaseFile $CreateScript
        Write-Host "[INFO] Database structure verified/created."
    }
    catch {
        Write-Warning "Database creation/verification failed: $_"
    }
}

# SECTION: Helper functions
function Get-LogonTypeName {
    param ([int]$Type)
    switch ($Type) {
        2  { 'Interactive' }
        3  { 'Network' }
        4  { 'Batch' }
        5  { 'Service' }
        7  { 'Unlock' }
        8  { 'NetworkCleartext' }
        9  { 'NewCredentials' }
        10 { 'RemoteInteractive' }
        11 { 'CachedInteractive' }
        default { 'Unknown' }
    }
}

function Resolve-Hostname {
    param ([string]$IPAddress)
    if ($IPAddress -in @('', '-', '::1')) {
        return ''
    }
    try {
        [System.Net.Dns]::GetHostEntry($IPAddress).HostName
    } catch {
        ''
    }
}

function TryInt {
    param ([object]$value)
    $text = $value.ToString().Trim()
    if ($text -in @('', '-', 'N/A')) {
        return 0
    }
    if ($text -match '^\d+$') {
        return [int]$text
    } else {
        return 0
    }
}

function Convert-WMIEvent {
    param ([object]$wmiEvent)
    $converted = [PSCustomObject]@{
        Id          = $wmiEvent.EventCode
        TimeCreated = [System.Management.ManagementDateTimeConverter]::ToDateTime($wmiEvent.TimeGenerated)
        UserId      = @{ Value = $wmiEvent.InsertionStrings[5] }
        Properties  = @(for ($i = 0; $i -lt 21; $i++) {
            [PSCustomObject]@{ Value = $wmiEvent.InsertionStrings[$i] }
        })
    }
    return $converted
}

# SECTION: Status code mapping
$StatusMap = @{
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

function Get-FailureDescription {
    param ([string]$StatusCode)
    if ($StatusMap.ContainsKey($StatusCode)) {
        $StatusMap[$StatusCode]
    } else {
        'Unknown status'
    }
}

# SECTION: Initialize database
Write-Host "[INFO] Initializing database..."
New-Database

# SECTION: Event Collection
Write-Host "[INFO] Starting event collection..."

$i = 0
$InvalidStructureCount = 0

foreach ($DC in $DomainControllers) {

    if (-not (Test-Connection -ComputerName $DC -Count 2 -Quiet)) {
        Write-Warning "Cannot reach $DC. Skipping."
        continue
    }

    Write-Host "[INFO] Connected to $DC. Retrieving events..."

    try {
        if ($DC -eq 'ttbvmdc01') {
            Write-Host "[INFO] Using WMI method for $DC"
            $RawEvents = Invoke-Command -ComputerName $DC -ScriptBlock {
                param ($pStartUTC)
                Get-WmiObject -Class Win32_NTLogEvent -Filter "Logfile='Security' AND EventCode=4625" |
                Where-Object {
                    ([System.Management.ManagementDateTimeConverter]::ToDateTime($_.TimeGenerated) -gt $pStartUTC)
                }
            } -ArgumentList (Get-Date).AddDays(-1)

            $LogonEvents = $RawEvents | Where-Object { $_.InsertionStrings.Count -ge 21 } |
                ForEach-Object { Convert-WMIEvent $_ }

        } else {
            Write-Host "[INFO] Using standard method for $DC"
            $LogonEvents = Get-WinEvent -ComputerName $DC -FilterHashtable @{
                LogName = $EventLogName
                Id      = $EventIDs
            }
        }
    } catch {
        Write-Warning "Error retrieving events from ${DC}: $_"
        continue
    }

    foreach ($LogonEvent in $LogonEvents) {
        $i++
        if ($i % 20 -eq 0) { Write-Host -NoNewline "." }

        $P = $LogonEvent.Properties
        if ($null -eq $P -or $P.Count -ne 21) {
            $InvalidStructureCount++
            Write-Warning "Event has $($P?.Count) properties (expected: 21)."
            continue
        }

        try {
            $getValue = {
                param($idx)
                if ($P.Count -gt $idx -and $P[$idx].Value) {
                    $P[$idx].Value.ToString()
                } else {
                    ''
                }
            }

            $RawLogonType  = & $getValue 4
            $LogonType     = 0
            $LogonTypeName = 'Unknown'
            if ($RawLogonType -match '^\d+$') {
                $LogonType     = [int]$RawLogonType
                $LogonTypeName = Get-LogonTypeName $LogonType
            }

            $Record = @{
                EventID                   = $LogonEvent.Id
                TimeStamp                 = if ($LogonEvent.TimeCreated) { $LogonEvent.TimeCreated.ToString("o") } else { '' }
                SubjectUserSid            = & $getValue 0
                SubjectUserName           = & $getValue 1
                SubjectDomainName         = & $getValue 2
                SubjectLogonId            = & $getValue 3
                LogonType                 = $LogonType
                LogonTypeName             = $LogonTypeName
                TargetUserSid             = & $getValue 5
                TargetUserName            = & $getValue 6
                TargetDomainName          = & $getValue 7
                StatusCode                = & $getValue 8
                SubStatusCode             = & $getValue 9
                FailureReason             = & $getValue 10
                WorkstationName           = & $getValue 11
                SourceNetworkAddress      = & $getValue 12
                SourcePort                = TryInt (& $getValue 13)
                ProcessId                 = TryInt (& $getValue 14)
                ProcessName               = & $getValue 15
                LogonProcessName          = & $getValue 16
                AuthenticationPackageName = & $getValue 17
                TransitedServices         = & $getValue 18
                PackageName               = & $getValue 19
                KeyLength                 = TryInt (& $getValue 20)
                ResolvedHost              = Resolve-Hostname (& $getValue 12)
                DCSource                  = $DC
                AccountName               = if ($LogonEvent.UserId) { $LogonEvent.UserId.Value.ToString() } else { '' }
                FailureDescription        = Get-FailureDescription (& $getValue 8)
            }

            $Cols      = $Record.Keys -join ', '
            $Vals      = $Record.Values | ForEach-Object {
                if ($_ -is [ValueType]) {
                    "$_"
                } else {
                    "'$($_.ToString().Replace("'", "''"))'"
                }
            }
            $ValString = $Vals -join ', '

        # INSERT OR IGNORE nutzen, um Unique-Verstöße still zu überspringen
        $Sql = "BEGIN; INSERT OR IGNORE INTO FailedLogons ($Cols) VALUES ($ValString); COMMIT;"

        # ausführen und Ausgaben unterdrücken
        & $SqliteExe $DatabaseFile $Sql | Out-Null


        } catch {
            Write-Warning "Error processing event from ${DC}: $_"
            continue
        }
    }
}

Write-Host ""
Write-Host "[INFO] Event collection complete."
Write-Host "[INFO] Total events processed: $i"
Write-Host "[INFO] Events with structural issues: $InvalidStructureCount"