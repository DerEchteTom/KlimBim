# Load helper functions and globals
. "$PSScriptRoot\helper.ps1"

# Optional: enable CLI output for debugging
$DebugOutput = $false

# Define excluded publishers (no case-insensitive)
$excludedPublishers = @()  # Leere Liste
#$excludedPublishers = @("microsoft", "adobe", "oracle", "nvidia")  # Add or remove terms as needed

# Show all snapshots
function Show-AllSnapshots {
    $query = "SELECT SnapshotID, CreatedAt, IsInitial FROM Snapshots ORDER BY CreatedAt;"
    $snapshots = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent

    Write-Host "`nAvailable snapshots:"
    Write-Host "---------------------------------------------"
    Write-Host "ID`tCreatedAt`t`tType"
    Write-Host "---------------------------------------------"

    $snapshots | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 3) {
            $id = $parts[0].Trim()
            $created = $parts[1].Trim()
            $isInitial = $parts[2].Trim()
            $type = if ($isInitial -eq "1") { "Initial" } else { "Incremental" }
            Write-Host "$id`t$created`t$type"
        }
    }
}

# Select by date
function Select-ByDate {
    $fromDate = Read-Host "From date (yyyy-MM-dd)"
    $toDate = Read-Host "To date (yyyy-MM-dd)"
    Write-Host "Searching for snapshots between $fromDate and $toDate..."

    $query = "SELECT SnapshotID FROM Snapshots WHERE CreatedAt BETWEEN '$fromDate' AND '$toDate';"
    $result = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent

    Write-Host "Found $($result.Count) snapshot(s) in that range."
    return $result
}

# Select by ID
function Select-ByID {
    $fromID = Read-Host "Start SnapshotID"
    $toID = Read-Host "End SnapshotID"
    Write-Host "Selecting snapshots from ID $fromID to $toID..."

    $query = "SELECT SnapshotID FROM Snapshots WHERE SnapshotID BETWEEN $fromID AND $toID;"
    $result = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent

    Write-Host "Found $($result.Count) snapshot(s) in that range."
    return $result
}

# Select last N snapshots
function Select-LastN {
    $count = Read-Host "How many of the most recent snapshots?"
    if (-not ($count -as [int])) {
        Write-Host "Invalid number. Please enter a numeric value." -ForegroundColor Yellow
        return @()
    }

    Write-Host "Selecting the last $count snapshot(s)..."
    $query = "SELECT SnapshotID FROM Snapshots ORDER BY CreatedAt DESC LIMIT $count;"
    $result = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent

    Write-Host "Found $($result.Count) snapshot(s)."
    return $result
}

# Main selection loop
do {
    Write-Host "`nHow would you like to select the range?"
    Write-Host "1 = By date"
    Write-Host "2 = By SnapshotID"
    Write-Host "3 = Last N snapshots"
    Write-Host "4 = By InstallDate"
    Write-Host "0 = Exit"

    $mode = Read-Host "Select mode (0/1/2/3/4)"

    if ($mode -eq '0') {
        Write-Host "Exiting script."
        exit
    }

    if ($mode -in @('1', '2', '3', '4')) {
        Show-AllSnapshots
        switch ($mode) {
            '1' { $snapshotIDs = Select-ByDate }
            '2' { $snapshotIDs = Select-ByID }
            '3' { $snapshotIDs = Select-LastN }
            '4' { $installDateMode = $true }
        }

        if (-not $installDateMode) {
            $snapshotIDs = $snapshotIDs | Where-Object { $_.Trim() -ne "" } | ForEach-Object { $_.Trim() }
            Write-Host "`nSelected SnapshotIDs: $($snapshotIDs -join ', ')" -ForegroundColor Green
        }

        break
    } else {
        Write-Host "Invalid selection. Please try again." -ForegroundColor Yellow
    }
} while ($true)

# Generate HTML for Filter list
function IsExcludedPublisher($publisher) {
    if (-not $publisher -or $publisher -eq "-") { return $false }

    $normalizedPublisher = $publisher.ToLower()

    foreach ($term in $excludedPublishers) {
        if ($normalizedPublisher.Contains($term.ToLower())) {
            return $true
        }
    }
    return $false
}

# Ensure output folder exists
New-Item -ItemType Directory -Path ".\report" -Force | Out-Null

# Prepare HTML file
# Optional: show filter info
$filterInfoHtml = "<strong>Excluded Publishers:</strong> $($excludedPublishers -join ', ')"
$timestamp   = Get-Date -Format "yyyyMMdd_HHmm"
$reportDate  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$reportType  = if ($installDateMode) { "Apps by InstallDate" } else { "Snapshot Diff" }
# Define output path
$htmlPath    = ".\report\report_${timestamp}_diff.html"

$htmlHeader = @"
<html>
<head>
    <title>Snapshot Diff Report - $reportType</title>
    <style>
        body {
            font-family: Segoe UI, sans-serif;
            background-color: #f3f3f3;
            color: #333;
            margin: 40px;
        }
        h2 {
            color: #0078d7;
        }
        p {
            font-size: 14px;
            margin-bottom: 20px;
        }
        table {
            border-collapse: collapse;
            width: 100%;
            background-color: white;
        }
        th, td {
            border: 1px solid #ccc;
            padding: 8px 12px;
            text-align: left;
        }
        th {
            background-color: #0078d7;
            color: white;
        }
        tr:nth-child(even) {
            background-color: #f9f9f9;
        }
    </style>
</head>
<body>
<h2>Snapshot Diff Report</h2>
<p><strong>Type:</strong> $reportType <strong>  Generated:</strong> $reportDate $filterInfoHtml</p>
<table>
<tr>
    <th>SnapshotID</th>
    <th>DisplayName</th>
    <th>Version</th>
    <th>Publisher</th>
    <th>Source</th>
    <th>InstallDate</th>
</tr>
"@
$htmlHeader | Out-File $htmlPath -Encoding UTF8

# Option 4: Filter by InstallDate
if ($installDateMode) {
    $fromDate = Read-Host "From InstallDate (yyyy-MM-dd)"
    $toDate   = Read-Host "To InstallDate (yyyy-MM-dd)"
    Write-Host "Searching for apps installed between $fromDate and $toDate..."

    $query = @"
SELECT SnapshotID, DisplayName, Version, Publisher, Source, InstallDate
FROM SnapshotApps
WHERE InstallDate BETWEEN '$fromDate' AND '$toDate'
ORDER BY InstallDate;
"@

    $apps = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent
    Write-Host "Found $($apps.Count) app(s)."

    foreach ($line in $apps) {
        $parts = $line -split '\|'
        if ($parts.Count -ge 6) {
            $id          = if ($parts[0].Trim()) { $parts[0].Trim() } else { "-" }
            $name        = if ($parts[1].Trim()) { $parts[1].Trim() } else { "-" }
            $version     = if ($parts[2].Trim()) { $parts[2].Trim() } else { "-" }
            $publisher   = if ($parts[3].Trim()) { $parts[3].Trim() } else { "-" }
            $source      = if ($parts[4].Trim()) { $parts[4].Trim() } else { "-" }
            $installDate = if ($parts[5].Trim()) { $parts[5].Trim() } else { "-" }

            # Hardcoded filter: exclude
            if (IsExcludedPublisher($publisher)) { continue }

            $row = "<tr><td>$id</td><td>$name</td><td>$version</td><td>$publisher</td><td>$source</td><td>$installDate</td></tr>`n"
            $row | Out-File $htmlPath -Append -Encoding UTF8
        }
    }

    $htmlFooter = @"
</table>
</body>
</html>
"@
    $htmlFooter | Out-File $htmlPath -Append -Encoding UTF8

    Write-Host "Report saved to: $htmlPath" -ForegroundColor Green
    exit
}

# Output apps per snapshot (default mode)
foreach ($idRaw in $snapshotIDs) {
    $id = $idRaw.Trim()
    if ($DebugOutput) {
        Write-Host ""
        Write-Host "Snapshot ${id}:"
    }

    $query = @"
SELECT DisplayName, Version, Publisher, Source, InstallDate
FROM SnapshotApps
WHERE SnapshotID = $id;
"@

    $apps = Invoke-SqliteCli -DbFile $Global:InstallDbPath -Sql $query -Silent

        if ($DebugOutput) {
        Write-Host "Apps found: $($apps.Count)"
        if ($apps.Count -eq 0) {
            Write-Host "  (No apps found)"
        }
    }

    foreach ($line in $apps) {
        $parts = $line -split '\|'
        if ($parts.Count -ge 5) {
            $name        = if ($parts[0].Trim()) { $parts[0].Trim() } else { "-" }
            $version     = if ($parts[1].Trim()) { $parts[1].Trim() } else { "-" }
            $publisher   = if ($parts[2].Trim()) { $parts[2].Trim() } else { "-" }
            $source      = if ($parts[3].Trim()) { $parts[3].Trim() } else { "-" }
            $installDate = if ($parts[4].Trim()) { $parts[4].Trim() } else { "-" }

            # Filter publisher
            if (IsExcludedPublisher($publisher)) {
            if ($DebugOutput) {
                Write-Host "Excluded: $name ($publisher)"
            }
            continue
            }
            if ($DebugOutput) {
                Write-Host "  $name | $version | $publisher | $source | $installDate"
            }

            $row = "<tr><td>$id</td><td>$name</td><td>$version</td><td>$publisher</td><td>$source</td><td>$installDate</td></tr>`n"
            $row | Out-File $htmlPath -Append -Encoding UTF8
        }

        
    }
}

# Finalize HTML
$htmlFooter = @"
</table>
</body>
</html>
"@
$htmlFooter | Out-File $htmlPath -Append -Encoding UTF8
Write-Host "Report saved to: $htmlPath" -ForegroundColor Green