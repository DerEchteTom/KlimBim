<#
.SYNOPSIS
  Imports failed logon events via WMI from two Domain Controllers and writes them into an SQLite database.
.VERSION
  2.1.2
#>

# region Configuration
. "$PSScriptRoot\..\Config-Helper.ps1"

$SqliteExe           = Get-SqliteExePath
$DatabaseFile        = Get-DatabasePath
$EventLogName        = Get-ConfigValue 'EventLogName'
$EventIDs            = @(4625)
$DomainControllers   = @('ttbvmdc01', 'ttbvmdc02')
# endregion

# region Logging
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = 'INFO'
    )
    Write-Host "[$Level] $Message"
}
# endregion

# region Mapping
$LogonTypeMap = @{
    0  = 'System'; 2  = 'Interactive'; 3  = 'Network'; 4  = 'Batch'
    5  = 'Service'; 7  = 'Unlock'; 8  = 'NetworkCleartext'; 9  = 'NewCredentials'
    10 = 'RemoteInteractive'; 11 = 'CachedInteractive'; 12 = 'CachedRemoteInteractive'; 13 = 'CachedUnlock'
}

$StatusMap = @{
    '0xC000006D' = 'Logon failed'; '0xC000006A' = 'Wrong password'
    '0xC0000064' = 'User does not exist'; '0xC0000234' = 'Account locked out'
    '0xC0000070' = 'Logon time restriction'; '0xC0000071' = 'Password expired'
    '0xC0000133' = 'Clock skew'; '0xC0000225' = 'Unknown user name'
    '0xC000015B' = 'Not allowed to logon'
}
# endregion
# region Database Management
function Get-DatabaseVersion {
    & $SqliteExe $DatabaseFile "PRAGMA user_version;" |
        Out-String |
        ForEach-Object { [int]$_.Trim() }
}

function New-Database {
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
  UNIQUE(EventID, TimeStamp, SubjectUserName, SourceNetworkAddress)
);
"@
    $CreateScript | & $SqliteExe $DatabaseFile
    Write-Log "Database initialized successfully."
}

function Initialize-Database {
    $MaxSizeMB     = 1024
    $WarningSizeMB = 800

    # BEGIN EnsureDataDir
    $DatabaseFile = Get-DatabasePath -Validate:$false
    $DataDir = Split-Path $DatabaseFile
    $BackupDir = Join-Path $DataDir 'backup'

    if (-not (Test-Path $DataDir)) {
        try {
            New-Item -Path $DataDir -ItemType Directory -Force | Out-Null
            Write-Log "Data-Verzeichnis erstellt: $DataDir" 'INFO'
        } catch {
            Write-Log "Fehler beim Erstellen von '$DataDir': $($_.Exception.Message)" 'ERROR'
            throw $_
        }
    }

    if (-not (Test-Path $BackupDir)) {
        New-Item $BackupDir -ItemType Directory | Out-Null
    }
    # END EnsureDataDir

    if (Test-Path $DatabaseFile) {
        $SizeMB  = (Get-Item $DatabaseFile).Length / 1MB
        $Version = Get-DatabaseVersion

        # 👉 Neu: Schema-Feldprüfung
        $ExpectedFields = @(
            'EventID','TimeStamp','SubjectUserSid','SubjectUserName','SubjectDomainName','SubjectLogonId',
            'LogonType','LogonTypeName','TargetUserSid','TargetUserName','TargetDomainName',
            'StatusCode','SubStatusCode','FailureReason','WorkstationName','SourceNetworkAddress',
            'SourcePort','ProcessId','ProcessName','LogonProcessName','AuthenticationPackageName',
            'TransitedServices','PackageName','KeyLength','ResolvedHost','DCSource'
        )
        try {
            $SchemaFields = & $SqliteExe $DatabaseFile "PRAGMA table_info(FailedLogons);" | ForEach-Object {
                ($_ -split '\|')[1]
            }
            foreach ($Field in $ExpectedFields) {
                if (-not $SchemaFields -contains $Field) {
                    Write-Log "Schema mismatch: missing field '$Field'" 'WARN'
                    $Version = -1  # Trigger Neuaufbau
                    break
                }
            }
        } catch {
            Write-Log "Error during schema validation: $($_.Exception.Message)" 'ERROR'
            $Version = -1
        }

        if ($SizeMB -gt $WarningSizeMB) {
            Write-Log "Warning: DB size is $([math]::Round($SizeMB,1)) MB." 'WARN'
        }

        if ($SizeMB -gt $MaxSizeMB -or $Version -ne 1) {
            $Timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
            $BackupFile = Join-Path $BackupDir "failed_logins_$Timestamp.db"
            Copy-Item $DatabaseFile $BackupFile -Force
            Remove-Item $DatabaseFile -Force
            Write-Log "Backup created: $BackupFile" 'WARN'
            New-Database
        }
    } else {
        Write-Log "Creating new database…" 'INFO'
        New-Database
    }
}
# endregion

#region WMI Event Collector (CIM-based, Full Pull)
function Get-FailedLogonEventsWMI {
    param (
        [string[]]$DCs,
        [string]$EventLog = "Security",
        [int[]]$EventIDs = @(4625)
    )

    $CollectedEvents = @()

    foreach ($DC in $DCs) {
        Write-Log "Querying $DC via CIM…" 'INFO'
        try {
            $Session = New-CimSession -ComputerName $DC
            foreach ($Id in $EventIDs) {
                $Query = "SELECT * FROM Win32_NTLogEvent WHERE LogFile = '$EventLog' AND EventCode = $Id"
                $Results = Get-CimInstance -CimSession $Session -Namespace "root\cimv2" -Query $Query
                foreach ($Ev in $Results) {
                    $Ev | Add-Member -MemberType NoteProperty -Name DCSource -Value $DC
                    $CollectedEvents += $Ev
                }
            }
            Remove-CimSession -CimSession $Session
        } catch {
            Write-Log "Error querying ${DC}: $($_.Exception.Message)" 'ERROR'
        }
    }

    return $CollectedEvents
}
#endregion

#region Event Import
function Import-FailedLogonsWMI {
    $Events = Get-FailedLogonEventsWMI -DCs $DomainControllers -EventLog $EventLogName -EventIDs $EventIDs
    $Imported = 0
    $Skipped  = 0
    $DCEventCounts = @{}

    foreach ($Ev in $Events) {
        try {
            $DC = $Ev.DCSource
            if (-not $DCEventCounts.ContainsKey($DC)) {
                $DCEventCounts[$DC] = 0
            }

            $Data    = $Ev.InsertionStrings
            $TimeStr = ([Management.ManagementDateTimeConverter]::ToDateTime($Ev.TimeGenerated)).ToString("yyyy-MM-dd HH:mm:ss")
            $IP      = $Data[11]
            $Status  = $Data[8]
            $Logon   = [int]$Data[4]

            try {
                $ResolvedHost = [System.Net.Dns]::GetHostEntry($IP).HostName
            } catch {
                $ResolvedHost = ''
            }

            $FailureReason = if ($StatusMap.ContainsKey($Status)) { $StatusMap[$Status] } else { 'Unknown status' }

            $Fields = @{
                EventID                   = $Ev.EventCode
                TimeStamp                 = $TimeStr
                SubjectUserSid            = $Data[0]
                SubjectUserName           = $Data[1]
                SubjectDomainName         = $Data[2]
                SubjectLogonId            = $Data[3]
                LogonType                 = $Logon
                LogonTypeName             = $LogonTypeMap[$Logon]
                TargetUserSid             = $Data[5]
                TargetUserName            = $Data[6]
                TargetDomainName          = $Data[7]
                StatusCode                = $Status
                SubStatusCode             = $Data[9]
                FailureReason             = $FailureReason
                WorkstationName           = $Data[10]
                SourceNetworkAddress      = $IP
                SourcePort                = [int]$Data[12]
                ProcessId                 = [int]$Data[13]
                ProcessName               = $Data[14]
                LogonProcessName          = $Data[15]
                AuthenticationPackageName = $Data[16]
                TransitedServices         = $Data[17]
                PackageName               = $Data[18]
                KeyLength                 = [int]$Data[19]
                ResolvedHost              = $ResolvedHost
                DCSource                  = $DC
            }

            $Columns = ($Fields.Keys -join ', ')
            $Values  = ($Fields.Values | ForEach-Object { "'$($_.ToString().Replace("'", "''"))'" }) -join ', '
            $SQL     = "INSERT OR IGNORE INTO FailedLogons ($Columns) VALUES ($Values);"

            & $SqliteExe $DatabaseFile $SQL
            $Imported++
            $DCEventCounts[$DC]++
        } catch {
            Write-Log "Skipped event due to error: $($_)" 'ERROR'
            $Skipped++
        }
    }

    Write-Log "$Imported events imported, $Skipped events skipped."

    foreach ($DC in $DCEventCounts.Keys) {
        Write-Log "Found $($DCEventCounts[$DC]) new events on $DC" 'INFO'
    }
}
#endregion