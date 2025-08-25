# Load configuration helper
. "$PSScriptRoot\..\Config-Helper.ps1"

# Define function to query failed logons from SQLite
function Get-FailedLogonsFromDB {
    param (
        [string]$SqliteExe,
        [string]$DatabasePath,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$TopN = 25
    )

    $startSql = $StartTime.ToString("yyyy-MM-dd HH:mm:ss")
    $endSql   = $EndTime.ToString("yyyy-MM-dd HH:mm:ss")

    $sql = @"
SELECT TargetUserName AS User, COUNT(*) AS Count
FROM FailedLogons
WHERE datetime(substr(TimeStamp,1,19)) BETWEEN '$startSql' AND '$endSql'
GROUP BY TargetUserName
ORDER BY Count DESC
LIMIT $TopN;
"@

    $raw = & $SqliteExe $DatabasePath ".mode list" ".header on" ".separator `"|`"" "$sql"
    $lines = $raw -split "`n" | Where-Object { $_ -match "\|" -and $_ -notmatch "^User\|Count$" }

    $results = @()
    foreach ($line in $lines) {
        $parts = $line -split "\|"

        $count = 0
        try {
            $count = [int]($parts[1].Trim())
        } catch {
            Write-Warning "Ungültiger Count-Wert: '$($parts[1])'"
        }

        $results += [pscustomobject]@{
            User  = $parts[0].Trim()
            Count = $count
        }
    }

    return $results
}

# Retrieve configuration values
$reportDir     = Get-ReportDirPath
$metaPath      = Get-MetaFilePath
$sqliteExe     = Get-SqliteExePath
$databasePath  = Get-DatabasePath
$excludedUsers = Get-ExcludedUsers
$htmlFilePath  = Get-HtmlReportPath -metaFilePath $metaPath

# Default values
$TopN            = 25
$To              = "user@domain.de"
$From            = "noreply@domain.de"
$SmtpServer      = "SMTP IP"
$SubjectTemplate = "IT Report - Top {0} failed logon users - {1:yyyy-MM-dd}"

Write-Host "Using meta file path: $metaPath"

# Load meta file
if (Test-Path $metaPath) {
    try {
        $meta = Get-Content -Path $metaPath -Raw | ConvertFrom-Json

        if ($meta.TopN -and $meta.TopN -gt 0) {
            $TopN = $meta.TopN
            Write-Host "[INFO] TopN overridden from meta: $TopN"
        }

        $reportStart = if ($meta.ReportStartTime) { [datetime]$meta.ReportStartTime } else { $null }
        $reportEnd   = if ($meta.ReportEndTime)   { [datetime]$meta.ReportEndTime }   else { $null }

        Write-Host "[INFO] Meta loaded successfully"
        if ($reportStart -and $reportEnd) {
            Write-Host "[INFO] Report period: $($reportStart.ToString('yyyy-MM-dd HH:mm')) to $($reportEnd.ToString('yyyy-MM-dd HH:mm'))"
        }
    } catch {
        Write-Warning "Failed to parse reportmeta.json - using default values"
    }
} else {
    Write-Warning "Meta file not found - using default values"
}

# Query failed logons
$entries = Get-FailedLogonsFromDB -SqliteExe $sqliteExe -DatabasePath $databasePath -StartTime $reportStart -EndTime $reportEnd -TopN $TopN

# Filter excluded users (case-insensitive)
$excludedUsersLower = $excludedUsers | ForEach-Object { $_.ToLower() }
$entries = $entries | Where-Object {
    $excludedUsersLower -notcontains $_.User.ToLower()
}

# Optional debug output
$filteredOut = $entries | Where-Object { $excludedUsersLower -contains $_.User.ToLower() }
if ($filteredOut.Count -gt 0) {
    Write-Host "Gefilterte User: $($filteredOut.User -join ', ')"
}

# Compose subject
$Subject = [string]::Format($SubjectTemplate, $TopN, (Get-Date))

# UNC path for HTML report
$localRoot        = "C:\Scripts\ReportingFailedLogins\report"
$networkShareRoot = "\\ttbvmdc02\report"
$relativePath     = $htmlFilePath.Substring($localRoot.Length).TrimStart('\')
$uncPath          = Join-Path $networkShareRoot $relativePath

# Generate plain text body
$textBody = @()
$textBody += "Security Alert Summary"
$textBody += "----------------------"
$textBody += ""
$textBody += "Report period: $($reportStart.ToString('yyyy-MM-dd HH:mm')) - $($reportEnd.ToString('yyyy-MM-dd HH:mm'))"
$textBody += "Full report available at: $uncPath"
$textBody += ""
$textBody += "Top $TopN failed logon users:"
$textBody += ""

foreach ($entry in $entries) {
    $textBody += "User: $($entry.User)"
    $textBody += "Failed Logons: $($entry.Count)"
    $textBody += "----------------------"
}

# Optional note about excluded users (in English)
if ($excludedUsers.Count -gt 0) {
    $textBody += ""
    $textBody += "Note: The following users were excluded from this report:"
    $textBody += ($excludedUsers -join ", ")
}

$PlainBody = $textBody -join "`r`n"

# Send email
try {
    Send-MailMessage `
        -To $To `
        -From $From `
        -Subject $Subject `
        -Body $PlainBody `
        -SmtpServer $SmtpServer

    Write-Host "Report sent to $To using SMTP server $SmtpServer"
} catch {
    Write-Host "Error sending email: $_" -ForegroundColor Red
}
