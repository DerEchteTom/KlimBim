# ============================
# snapshotmanager.ps1
# ============================
. "$PSScriptRoot\helper.ps1"
$dbFile = $Global:InstallDbPath

# 0.9) Unterschiede direkt nach der App-Ermittlung ...
$previousID = [int](Invoke-SqliteCli -DbFile $dbFile -Sql "SELECT MAX(SnapshotID) FROM Snapshots;" -Silent |
                    Where-Object { $_.Trim() -ne "" } |
                    Select-Object -First 1)



# ============================
# 1) Lokale Hilfsfunktionen
# ============================

function Get-StableKey($name, $version, $publisher) {
    $n = ($name      -as [string]); $n = if ($n) { $n.Trim().ToLowerInvariant() } else { "" }
    $v = ($version   -as [string]); $v = if ($v) { $v.Trim().ToLowerInvariant() } else { "" }
    $p = ($publisher -as [string]); $p = if ($p) { $p.Trim().ToLowerInvariant() } else { "" }
    $raw   = "$n|$v|$p"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    [System.BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash($bytes)) -replace '-', ''
}

function Convert-InstallDate($rawDate) {
    if ($rawDate -match '^\d{8}$') {
        return [datetime]::ParseExact($rawDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
    }
    return $null
}

function Get-InstalledApps {
    $sources = @(
        @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*";             Source = "HKLM"    },
        @{ Path = "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"; Source = "WOW6432" },
        @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*";             Source = "HKCU"    }
    )
    foreach ($entry in $sources) {
        Get-ItemProperty -Path $entry.Path -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.PSChildName } |
        ForEach-Object {
            $ver = if ($_.DisplayVersion) { $_.DisplayVersion } else { "unknown" }
            [PSCustomObject]@{
                UniqueKey   = $_.PSChildName
                DisplayName = $_.DisplayName
                Version     = $ver
                Publisher   = $_.Publisher
                Source      = $entry.Source
                InstallDate = Convert-InstallDate $_.InstallDate
                StableKey   = Get-StableKey $_.DisplayName $ver $_.Publisher
            }
        }
    }
}

# ============================
# 1a) Anzeige aller Snapshots
# ============================

function Show-AllSnapshots {
    $query = "SELECT SnapshotID, CreatedAt, IsInitial FROM Snapshots ORDER BY CreatedAt;"
    $snapshots = & $Global:SqliteExe $Global:InstallDbPath "$query"

    Write-Host ""
    Write-Host "Available snapshots:"
    Write-Host "---------------------------------------------"
    Write-Host "ID`tCreatedAt`t`tType"
    Write-Host "---------------------------------------------"
    Write-Host ""

    $snapshots | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
        $parts = $_ -split '\|'
        if ($parts.Count -ge 3) {
            $id = $parts[0].Trim()
            $created = $parts[1].Trim()
            $isInitial = $parts[2].Trim()
            $type = if ($isInitial -eq "1") { "Initial" } else { "Incremental" }

            Write-Host "$id`t$created`t$type"
            Write-Host ""
        }
    }
}

# ============================
# 2) Scan und Deduplication
# ============================

$appRows = Get-InstalledApps | Where-Object { $_.StableKey }
$appRows = $appRows | Sort-Object StableKey, UniqueKey
$appRows = $appRows | Group-Object StableKey | ForEach-Object { $_.Group[0] }
$appCount = [int]$appRows.Count

Write-Host ""
Write-Host "$appCount unique applications after deduplication."
if ($appCount -eq 0) { return }

# --- DEBUG: Vergleich mit vorherigem Snapshot ---
# Alte StableKeys laden, nur wenn es einen vorherigen Snapshot gibt
$oldList = @()
if ($previousID -and $previousID -gt 0) {
    $sqlKeysPrev = "SELECT StableKey, Version FROM SnapshotApps WHERE SnapshotID = $previousID ORDER BY StableKey;"
    $oldList = Invoke-SqliteCli -DbFile $dbFile -Sql $sqlKeysPrev -Silent |
               Where-Object { $_.Trim() -ne "" } |
               ForEach-Object {
                   $parts = $_ -split '\|'
                   [PSCustomObject]@{ StableKey = $parts[0]; Version = $parts[1] }
               }
}

# Neue Liste
$newList = $appRows | Select-Object StableKey, Version

Write-Host ""
Write-Host "Differences vs previous snapshot"

if ($oldList -and $oldList.Count -gt 0) {

    $diffs = Compare-Object -ReferenceObject $oldList `
                            -DifferenceObject $newList `
                            -Property StableKey, Version

    if ($diffs -and $diffs.Count -gt 0) {
        foreach ($d in $diffs) {
            if ($d.SideIndicator -eq '<=') {
                $side = 'REMOVED'
            }
            elseif ($d.SideIndicator -eq '=>') {
                $side = 'NEW'
            }
            else {
                $side = 'CHANGED'
            }

            $line = $side + ' | ' + $d.StableKey + ' | ' + $d.Version
            Write-Host $line -ForegroundColor Yellow
        }
    }
    else {
        Write-Host '0 differences - lists are identical' -ForegroundColor Green
    }

}
else {
    Write-Host 'No previous snapshot or no data available for comparison' -ForegroundColor DarkGray
}

Write-Host ""

# ============================
# 3) ScanHash berechnen
# ============================

$sortedKeys = ($appRows | Select-Object -ExpandProperty StableKey) | Sort-Object
$joined     = [string]::Join("`n", $sortedKeys)
$bytes      = [System.Text.Encoding]::UTF8.GetBytes($joined)
$scanHash   = [System.BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash($bytes)) -replace '-', ''

# ============================
# 4) Letzten Snapshot laden
# ============================

$sqlLast = @"
SELECT SnapshotID, IFNULL(ScanHash,''), IFNULL(AppCount,0)
FROM Snapshots
ORDER BY SnapshotID DESC
LIMIT 1;
"@
$lastRows = Invoke-SqliteCli -DbFile $dbFile -Sql $sqlLast -Silent | Where-Object { $_.Trim() -ne "" }

$previousID = $null
$lastHash   = ""
$lastAppCount = 0
$isInitial  = $true

if ($lastRows.Count -gt 0 -and $lastRows[0]) {
    $line  = ($lastRows -join '|')
    Write-Host "Raw line from DB: $line"
    $parts = $line -split '\|'
    if ($parts.Count -ge 3) {
        $previousID   = [int]$parts[0]
        $lastHash     = $parts[1]
        $lastAppCount = [int]$parts[2]
        $isInitial = ($previousID -le 0 -or $lastAppCount -eq 0)
    }
}

Write-Host "Parsed lastHash: $lastHash"
Write-Host "Parsed previousID: $previousID"
# Write-Host ""
# Write-Host "Parsed lastAppCount: $lastAppCount"
Write-Host ""
Write-Host "isInitial: $isInitial"


# ============================
# 5) Snapshot überspringen bei Gleichheit
# ============================

if (-not $isInitial -and $lastHash -eq $scanHash) {
    Write-Host "`nNo changes detected (ScanHash match). Snapshot skipped."
    Write-Host ""
    $lastInfoSql = @"
SELECT SnapshotID, CreatedAt, AppCount
FROM Snapshots
ORDER BY SnapshotID DESC
LIMIT 1;
"@
    $infoRow = Invoke-SqliteCli -DbFile $dbFile -Sql $lastInfoSql -Silent | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
    $infoParts = ([string]$infoRow) -split '\|'
    Write-Host ("Last snapshot: ID {0} | Date: {1} | Apps: {2}" -f $infoParts[0], $infoParts[1], $infoParts[2])
    Show-AllSnapshots
    return
}

# ============================
# 6) SQL-Diff bei inkrementellem Snapshot
# ============================

if (-not $isInitial) {
    $sqlDiff = @"
CREATE TEMP TABLE CurrentApps(StableKey TEXT PRIMARY KEY, Version TEXT);
"@
    foreach ($app in $appRows) {
        $sk  = $app.StableKey
        $ver = ($app.Version -as [string]).Replace("'", "''")
        $sqlDiff += "INSERT OR IGNORE INTO CurrentApps VALUES('$sk','$ver');`n"
    }
    $sqlDiff += @"
-- New
SELECT COUNT(*) FROM CurrentApps ca
 LEFT JOIN SnapshotApps sa
   ON sa.SnapshotID = $previousID AND sa.StableKey = ca.StableKey
WHERE sa.StableKey IS NULL;
-- Removed
SELECT COUNT(*) FROM SnapshotApps sa
 LEFT JOIN CurrentApps ca
   ON ca.StableKey = sa.StableKey
WHERE sa.SnapshotID = $previousID AND ca.StableKey IS NULL;
-- Updated
SELECT COUNT(*) FROM CurrentApps ca
 JOIN SnapshotApps sa
   ON sa.SnapshotID = $previousID AND sa.StableKey = ca.StableKey
WHERE IFNULL(sa.Version,'') <> IFNULL(ca.Version,'');
"@
    $diffResults = Invoke-SqliteCli -DbFile $dbFile -Sql $sqlDiff -Silent | Where-Object { $_.Trim() -ne "" }
    if (($diffResults | ForEach-Object { [int]$_ }) -eq @(0,0,0)) {
        Write-Host "`nNo changes detected (SQL diff). Snapshot skipped."

        $lastInfoSql = @"
SELECT SnapshotID, CreatedAt, AppCount
FROM Snapshots
ORDER BY SnapshotID DESC
LIMIT 1;
"@
        $infoRow = Invoke-SqliteCli -DbFile $dbFile -Sql $lastInfoSql -Silent | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
        $infoParts = ([string]$infoRow) -split '\|'
        Write-Host ("Last snapshot: ID {0} | Date: {1} | Apps: {2}" -f $infoParts[0], $infoParts[1], $infoParts[2])
        Show-AllSnapshots
        return
    }
}

# ============================
# 7) Snapshot speichern
# ============================

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$note      = if ($isInitial) { "Initial system state" } else { "Automated snapshot" }
$isInitialInt = if ($isInitial) { 1 } else { 0 }

Write-Host "Calculated scanHash: $scanHash"

$sqlInsertSnapshot = @"
INSERT INTO Snapshots (CreatedAt, Note, AppCount, ScanHash, IsInitial)
VALUES ('$timestamp', '$note', $appCount, '$scanHash', $isInitialInt);
"@
Invoke-SqliteCli -DbFile $dbFile -Sql $sqlInsertSnapshot -Silent

$checkSql = "SELECT SnapshotID, length(ScanHash) AS HashLen, ScanHash FROM Snapshots ORDER BY SnapshotID DESC LIMIT 1;"
$checkRow = Invoke-SqliteCli -DbFile $dbFile -Sql $checkSql -Silent | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
Write-Host "DB after insert: $checkRow"

# ============================
# 8) Snapshot-ID prüfen und Apps einfügen
# ============================

$checkRow = Invoke-SqliteCli -DbFile $dbFile -Sql $checkSql -Silent | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1
Write-Host "DB after insert: $checkRow"

$snapshotID = [int](Invoke-SqliteCli -DbFile $dbFile -Sql "SELECT MAX(SnapshotID) FROM Snapshots;" -Silent | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
if ($snapshotID -le 0) {
    Write-Host "Could not get SnapshotID, aborting."
    return
}

Write-Host "Creating snapshot: $note (ID: $snapshotID)"

foreach ($app in $appRows) {
    $stableKey   = $app.StableKey
    $uniqueKey   = ($app.UniqueKey   -as [string]) -replace "'", "''"
    $name        = ($app.DisplayName -as [string]) -replace "'", "''"
    $version     = ($app.Version     -as [string]) -replace "'", "''"
    $publisher   = ($app.Publisher   -as [string]) -replace "'", "''"
    $source      = ($app.Source      -as [string]) -replace "'", "''"
    $installDate = ($app.InstallDate -as [string])

    $sqlAppInsert = @"
INSERT INTO SnapshotApps (
    SnapshotID, StableKey, UniqueKey, DisplayName, Version,
    Publisher, Source, InstallDate
) VALUES (
    $snapshotID, '$stableKey', '$uniqueKey', '$name', '$version',
    '$publisher', '$source', '$installDate'
);
"@
    Invoke-SqliteCli -DbFile $dbFile -Sql $sqlAppInsert -Silent
}

# ============================
# 9) Abschlussausgabe zum Snapshot
# ============================

$modeText = if ($isInitial) { "Initial system state" } else { "Incremental" }
Write-Host "`nSnapshot $snapshotID created: $modeText"
Write-Host ""
Write-Host "Apps: $appCount"
Write-Host ""
Write-Host "ScanHash: $scanHash"
Write-Host ""
Write-Host "`nSnapshot $snapshotID created with $appCount apps."


# ============================
# 11) Immer anzeigen – egal ob Snapshot erstellt wurde
# ============================

Show-AllSnapshots