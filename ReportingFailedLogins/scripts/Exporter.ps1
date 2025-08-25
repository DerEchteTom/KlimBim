# Exporter.ps1 – Failed Logons HTML Exporter

# === User Settings ===
$Limit         = 999
$UseUserFilter = $true
$ShowStep      = 'HTML'

# === Load Config & Helpers ===
. "$PSScriptRoot\..\Config-Helper.ps1"

$sqliteExe     = Get-SqliteExePath
$dbFile        = Get-DatabasePath
$fields        = Get-FieldsConfig
$excludedUsers = Get-ExcludedUsers
$reportDir     = Get-ReportDirPath
$metaFile      = Get-MetaFilePath

# === Load Metadata ===
$Meta = Load-Meta


# === Time Range via exportconfig.json ===
$ExportConfigPath = Join-Path $PSScriptRoot 'exportconfig.json'
$ManualExport     = $false

$endTime   = Get-Date
$startTime = $endTime.AddDays(-1)

if (Test-Path $ExportConfigPath) {
    try {
        $configRaw = Get-Content $ExportConfigPath -Raw
        $config    = $configRaw | ConvertFrom-Json

        if (-not ($config.StartTime -and $config.EndTime)) {
            Write-Host "[ERROR] exportconfig.json is present but missing valid time values."
            Write-Host "[HINT] Example: { `"StartTime`": `"2024-08-01T00:00:00Z`", `"EndTime`": `"2024-08-03T23:59:59Z`" }"
            exit 1
        }

        $startTime = [DateTime]::Parse($config.StartTime)
        $endTime   = [DateTime]::Parse($config.EndTime)
        $ManualExport = $true
        Write-Host "[INFO] Manual export range detected: $startTime to $endTime"
    } catch {
        Write-Host "[ERROR] exportconfig.json could not be read or parsed."
        exit 1
    }
} else {
    Write-Host "[INFO] No exportconfig.json found - using default range: last 24 hours"
}

Write-Host "[INFO] Export time range: $($startTime.ToString('yyyy-MM-dd HH:mm')) to $($endTime.ToString('yyyy-MM-dd HH:mm'))"

# === Prepare Fields ===
$allFields = $fields.PSObject.Properties | Sort-Object { $_.Value.position }
$columnsList = ($allFields | ForEach-Object { $_.Name }) -join ", "

# === SQL Query ===
$sqlWhere = "WHERE datetime(substr(TimeStamp,1,19)) >= datetime('" + $startTime.ToString("yyyy-MM-dd HH:mm:ss") + "') AND datetime(substr(TimeStamp,1,19)) <= datetime('" + $endTime.ToString("yyyy-MM-dd HH:mm:ss") + "')"
$sqlLimit = if ($Limit) { "LIMIT $Limit" } else { "" }
$sqlQuery = "SELECT $columnsList FROM FailedLogons $sqlWhere $sqlLimit;"

# === Extract Data ===
$csvRaw   = & $sqliteExe -header -csv $dbFile $sqlQuery
$objects  = if ($csvRaw) { $csvRaw | ConvertFrom-Csv } else { @() }

# === Optional Filtering ===
$filteredUsers = if ($UseUserFilter) {
    $objects | Where-Object {
        -not ($excludedUsers -contains $_.SubjectUserName) -and
        -not ($excludedUsers -contains $_.TargetUserName)
    }
} else {
    $objects
}

$rows     = $filteredUsers
$rowCount = $rows.Count
Write-Host "[INFO] Rows selected after filtering: $($rowCount)"
if ($ShowStep -eq 'HTML') {
    $lastImport    = (Get-Item $dbFile).LastWriteTime
    $lastImportStr = $lastImport.ToString("yyyy-MM-dd HH:mm")
    $dateStamp     = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $targetPath    = Join-Path $reportDir "FailedLogons_$dateStamp.html"

    # === DB Age Color ===
    $dbAgeHours = [math]::Round(((Get-Date) - $lastImport).TotalHours, 0)
    if ($dbAgeHours -le 24) {
         $dbAgeColor = "green"
        $dbAgeLabel = "Fresh (up to 24h)"
        } elseif ($dbAgeHours -le 48) {
        $dbAgeColor = "orange"
        $dbAgeLabel = "Stale (25 to 48h)"
        } else {
        $dbAgeColor = "red"
        $dbAgeLabel = "Outdated (over 48h)"
    }

# === HTML Start ===
$htmlOut = @"
<html>
<head>
    <meta charset="UTF-8">
    <title>Failed Logons Report</title>
    <style>
        body {
            font-family: Segoe UI, sans-serif;
            font-size: 11px;
            margin: 18px;
            color: #333;
        }
        .scroll-container {
            overflow-x: auto;
            overflow-y: scroll;
            max-height: 600px;
            border: 1px solid #ccc;
            width: 100%;
        }
        table {
            border-collapse: collapse;
            min-width: max-content;
            table-layout: auto;
        }
        td {
        font-size: 11px;
        }           
        th, td {
            border: 1px solid #ccc;
            padding: 5px;
            text-align: left;
            vertical-align: top;
        }
        th {
            background-color: #0078D4;
            color: white;
            font-size: 11px;
            position: sticky;
            top: 0;
            z-index: 1;
            cursor: pointer;
        }
        h2 {
            color: #444;
            font-size: 16px;
        }
        .toggle-btn {
            background-color: #eee;
            border: 1px solid #aaa;
            padding: 5px 10px;
            cursor: pointer;
            margin-bottom: 10px;
        }
        .hidden-col {
            display: none;
        }
        .db-age {
            font-weight: bold;
        }
        tbody tr:nth-child(even) {
            background-color: #eaeaea;
        }
        tbody tr:nth-child(odd) {
            background-color: #ffffff;
        }
        tr.marked {
            background-color: #cce5ff !important;
        }
    </style>
    <script type="text/javascript">
        function toggleColumns() {
            var hidden = document.getElementsByClassName('hidden-col');
            for (var i = 0; i < hidden.length; i++) {
                hidden[i].style.display = (hidden[i].style.display === 'none' || hidden[i].style.display === '') ? 'table-cell' : 'none';
            }
        }

        document.addEventListener("DOMContentLoaded", function () {
            const rows = document.querySelectorAll("tbody tr");
            rows.forEach(row => {
                row.addEventListener("click", () => {
                    rows.forEach(r => r.classList.remove("marked"));
                    row.classList.add("marked");
                });
            });

            const headers = document.querySelectorAll("thead th");
            headers.forEach((header, index) => {
                header.addEventListener("click", () => {
                    const table = header.closest("table");
                    const tbody = table.querySelector("tbody");
                    const rowsArray = Array.from(tbody.querySelectorAll("tr"));

                    const isNumeric = !isNaN(rowsArray[0].children[index].textContent.trim());

                    rowsArray.sort((a, b) => {
                        const cellA = a.children[index].textContent.trim();
                        const cellB = b.children[index].textContent.trim();

                        return isNumeric
                            ? Number(cellA) - Number(cellB)
                            : cellA.localeCompare(cellB);
                    });

                    rowsArray.forEach(row => tbody.appendChild(row));
                });
            });
        });
    </script>
</head>
<body>
    <h2>Failed Logons Report</h2>
    <p>Export time range: $($startTime.ToString("yyyy-MM-dd HH:mm")) to $($endTime.ToString("yyyy-MM-dd HH:mm"))</p>
    <p>Last database import: <span class="db-age" style="color:$dbAgeColor;">$lastImportStr</span> ($dbAgeHours hours ago - $dbAgeLabel)</p>

    <button class="toggle-btn" onclick="toggleColumns()">Show / Hide all fields</button>

    <div class="scroll-container">
        <table>
            <thead>
                <tr>
"@

foreach ($f in $allFields) {
    $label = $f.Value.label.en
    $cssClass = if ($f.Value.enabled) { "" } else { "class='hidden-col'" }
    $htmlOut += "                    <th $cssClass>$label</th>`n"
}

$htmlOut += @"
                </tr>
            </thead>
            <tbody>
"@

if ($rows.Count -eq 0) {
    $htmlOut += "                <tr><td colspan='$($allFields.Count)'>No data available for selected time range.</td></tr>`n"
} else {
    foreach ($r in $rows) {
        $htmlOut += "                <tr>`n"
        foreach ($f in $allFields) {
            $value = $r.$($f.Name)

            if ($f.Name -eq "TimeStamp" -and $value) {
                try {
                    $parsed = [DateTime]::Parse($value)
                    $value = $parsed.ToString("yyyy-MM-dd HH:mm")
                } catch {}
            }

            $cssClass = if ($f.Value.enabled) { "" } else { "class='hidden-col'" }
            $htmlOut += "                    <td $cssClass>$value</td>`n"
        }
        $htmlOut += "                </tr>`n"
    }
}

$htmlOut += @"
            </tbody>
        </table>
    </div>
</body>
</html>
"@

# === Save HTML ===
try {
    $htmlOut | Set-Content -Encoding UTF8 $targetPath
    Write-Host "[SUCCESS] HTML report saved to: $targetPath"
} catch {
    Write-Host "[ERROR] Failed to save HTML report to: $targetPath"
    Write-Host $_.Exception.Message
    exit 1
}


    # === Update Meta ===
$Meta.HtmlReportPath      = $targetPath
$Meta.ReportCreatedAt     = Get-Date
$Meta.RecordCount         = $rowCount
$Meta.LastFailedLogonScan = $lastImport
$Meta.FailedEventCount    = $rowCount
$Meta.ReportStartTime = $startTime.ToString("o")
$Meta.ReportEndTime   = $endTime.ToString("o")
Save-Meta -Meta $Meta

}
