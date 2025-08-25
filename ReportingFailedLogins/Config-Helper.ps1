<# 
.SYNOPSIS
Stellt Zugriff auf die Konfiguration und zentrale Ressourcen bereit

# config-helper.ps1 #
#>

. "$PSScriptRoot\Path.ps1"

# Lade Config einmalig
$Global:__Config = Get-Config


function Get-ConfigValue {
    param([string]$Key)

    if ($Global:__Config.PSObject.Properties.Name -notcontains $Key) {
        throw "Key '$Key' not found in config.json."
    }

    return $Global:__Config.$Key
}

# Hilfs-Getter für Ressourcen
function Get-SqliteExePath     { return Get-FullPath $Global:__Config.SqliteExe }
function Get-DatabasePath      { return Get-FullPath $Global:__Config.DatabaseFile }
function Get-FieldsFilePath    { return Get-FullPath $Global:__Config.FieldsFile }
function Get-ExcludedUsersPath { return Get-FullPath $Global:__Config.ExcludedUsers }
function Get-ReportDirPath     { return Get-FullPath $Global:__Config.ReportDir }
function Get-MetaDirPath      { return Get-FullPath $Global:__Config.MetaDir }

# Optional: JSON-Dateien direkt laden
function Get-ExcludedUsers {
    $path = Get-ExcludedUsersPath
    if (-not (Test-Path $path)) {
        throw "excludedUsers.json not found: $path"
    }
    return Get-Content $path | ConvertFrom-Json
}

function Get-FieldsConfig {
    $path = Get-FieldsFilePath
    if (-not (Test-Path $path)) {
        throw "fields.json not found: $path"
    }
    return Get-Content $path | ConvertFrom-Json
}

function Get-MetaFilePath {
    return Get-FullPath $Global:__Config.MetaFile
}
function New-DefaultMeta {
    return [pscustomobject]@{
        HtmlReportPath      = ""
        ReportCreatedAt     = ""
        RecordCount         = 0
        LastFailedLogonScan = $null
        FailedEventCount    = 0
        ReportStartTime     = ""
        ReportEndTime       = ""
    }
}

function Load-Meta {
    $path = Get-MetaFilePath
    if (-not (Test-Path $path)) {
        Write-Host "[WARN] Meta file not found. Using defaults."
        return New-DefaultMeta
    }

    try {
        $raw = Get-Content $path -Raw | ConvertFrom-Json
        $meta = New-DefaultMeta
        foreach ($p in $raw.PSObject.Properties) {
            $meta | Add-Member -MemberType NoteProperty -Name $p.Name -Value $p.Value -Force
        }
        return $meta
    } catch {
        Write-Host "[WARN] Error parsing meta file. Using defaults."
        return New-DefaultMeta
    }
}

function Save-Meta {
    param(
        [Parameter(Mandatory)] $Meta,
        [string]$Path = $(Get-MetaFilePath)  # Nutzt Standardpfad, falls keiner übergeben wird
    )

    $Meta | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $Path
}


function Get-SafeTime {
    param(
        [datetime]$ReferenceTime,
        [int]$BufferMinutes = 10
    )

    if (-not $ReferenceTime) {
        return (Get-Date).AddHours(-24)  # Default: letzte 24h
    }

    return $ReferenceTime.AddMinutes(-$BufferMinutes)
}

function Get-HtmlReportPath {
    param ([string]$metaFilePath)

    $meta = Get-Content $metaFilePath | ConvertFrom-Json
    return $meta.HtmlReportPath
}
