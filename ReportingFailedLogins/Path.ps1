function Get-ProjectRoot {
    return $PSScriptRoot
}

function Get-ConfigFilePath {
    return Join-Path (Get-ProjectRoot) "config/config.json"
}

function Write-ErrorLog($message) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logPath = Join-Path (Get-ProjectRoot) "log/error.log"
    "$timestamp | $message" | Out-File -Append -FilePath $logPath -Encoding UTF8
}

function Get-Config {
    $cfgPath = Get-ConfigFilePath

    if (-not (Test-Path $cfgPath)) {
        $msg = "ConfigurationsFile not found: $cfgPath"
        Write-ErrorLog $msg
        throw $msg
    }

    try {
        return Get-Content $cfgPath -Raw | ConvertFrom-Json
    } catch {
        $msg = "configuration file parsing error: $_"
        Write-ErrorLog $msg
        throw $msg
    }
}

# BEGIN FullPath
function Get-FullPath {
    param (
        [string]$RelativePath,
        [bool]$Validate = $true
    )

    if (-not $RelativePath) {
        $msg = "relative path problems."
        Write-ErrorLog $msg
        throw $msg
    }

    $basePath = Get-ProjectRoot
    $fullPath = Join-Path $basePath $RelativePath

    if ($Validate -and -not (Test-Path $fullPath)) {
        Write-Warning "Path not found: $fullPath (trying to create)"
        Write-ErrorLog "Path not found: $fullPath"
    }

    return $fullPath
}
# END FullPath
