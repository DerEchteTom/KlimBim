. "$PSScriptRoot\helper.ps1"

# Ensure output folder exists
New-Item -ItemType Directory -Path ".\report" -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$outputFile = ".\report\report_$timestamp.html"
$dbPath = $Global:InstallDbPath

# HTML Header
$global:html = @"
<!DOCTYPE html>
<html lang='en'>
<head>
  <meta charset='UTF-8'>
  <title>Installation Report - $timestamp</title>
  <style>
    body { font-family: Segoe UI, sans-serif; background-color: #f3f3f3; margin: 0; padding: 20px; }
    h1, h2 { color: #2b2b2b; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }
    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; }
    th { background-color: #e1e1e1; }
    tr:nth-child(even) { background-color: #f9f9f9; }
    .section { margin-bottom: 50px; }
  </style>
</head>
<body>
  <h1>Installation Report</h1>
  <p>Generated at $timestamp</p>
"@

# Function to render SQL output as HTML table
function Add-TableSection {
  param (
    [string]$Title,
    [string]$Sql,
    [string[]]$Headers
  )

  $global:html += "<div class='section'><h2>$Title</h2><table>"

  $raw = Invoke-SqliteCli -DbFile $dbPath -Sql $Sql -Silent
  $raw = $raw | Where-Object { $_.Trim() -ne "" }

  if ($raw.Count -eq 0) {
    $global:html += "<tr><td>No data available</td></tr></table></div>"
    return
  }

  $global:html += "<tr>" + ($Headers | ForEach-Object { "<th>$_</th>" }) -join "" + "</tr>"

  foreach ($line in $raw) {
    $cells = $line.Split('|')
    $global:html += "<tr>" + ($cells | ForEach-Object { "<td>$_</td>" }) -join "" + "</tr>"
  }

  $global:html += "</table></div>"
}

# SQL Queries
$sqlSnapshots = @"
SELECT SnapshotID, CreatedAt, Note, AppCount, substr(ScanHash,1,12) AS ScanHash
FROM Snapshots
ORDER BY SnapshotID DESC;
"@

$sqlAppsPerSnapshot = @"
SELECT SnapshotID, DisplayName, Version, Publisher, Source, InstallDate
FROM SnapshotApps
ORDER BY SnapshotID, DisplayName;
"@

$sqlFirstSeen = @"
SELECT DisplayName, MIN(S.CreatedAt) AS FirstSeen
FROM SnapshotApps A
JOIN Snapshots S ON A.SnapshotID = S.SnapshotID
GROUP BY DisplayName
ORDER BY FirstSeen;
"@

$sqlAppCountTrend = @"
SELECT CreatedAt, AppCount
FROM Snapshots
ORDER BY CreatedAt;
"@

# Add sections
Add-TableSection "Snapshot Overview" $sqlSnapshots @("SnapshotID", "CreatedAt", "Note", "AppCount", "ScanHash")
Add-TableSection "Installed Applications per Snapshot" $sqlAppsPerSnapshot @("SnapshotID", "DisplayName", "Version", "Publisher", "Source", "InstallDate")
Add-TableSection "Installation Timeline" $sqlFirstSeen @("DisplayName", "FirstSeen")
Add-TableSection "App Count Trend" $sqlAppCountTrend @("CreatedAt", "AppCount")

# HTML Footer
$global:html += "</body></html>"

# Save to file
$global:html | Out-File -Encoding UTF8 $outputFile
Write-Host "Report saved to $outputFile"