# cleaner.ps1
# Archives HTML reports older than 14 days (recursively) and deletes ZIPs older than 180 days.
# Additionally archives DB backups matching failed_logins.db.bak_YYYYMMDD_HHMMSS (recursively).
# Encoding-safe for Task Scheduler (no Console handle required).

# --- Encoding: enforce UTF-8 for file outputs (console set only if available) ---
try {
    if ($Host.Name -ne 'DefaultHost') {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

# --- Settings / Helpers ---
. "$PSScriptRoot\..\Config-Helper.ps1"

$reportDir = Get-ReportDirPath
$metaFile  = Get-MetaFilePath
$backupDir = Split-Path -Parent $metaFile

if (-not (Test-Path -LiteralPath $reportDir)) { Write-Host "[ERROR] Report directory not found: $reportDir"; exit 1 }
if (-not (Test-Path -LiteralPath $backupDir)) { Write-Host "[ERROR] Backup directory not found: $backupDir"; exit 1 }

$timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$cutoffHtml  = (Get-Date).AddDays(-14)
$cutoffZip   = (Get-Date).AddDays(-180)

# Zip targets
$zipHtmlName = "ArchivedReports_$timestamp.zip"
$zipHtmlPath = Join-Path $reportDir $zipHtmlName

$zipBakName  = "ArchivedBackups_$timestamp.zip"
$zipBakPath  = Join-Path $backupDir $zipBakName

# === Step 1A: Archive HTML files older than 14 days (recursive) ===
$oldHtmlFiles = Get-ChildItem -Path $reportDir -Filter *.html -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoffHtml }

if ($oldHtmlFiles -and $oldHtmlFiles.Count -gt 0) {
    $totalSizeBytes = ($oldHtmlFiles | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB    = if ($totalSizeBytes) { [Math]::Round($totalSizeBytes / 1MB, 2) } else { 0 }
    Write-Host "[INFO] Archiving $($oldHtmlFiles.Count) HTML files (~$totalSizeMB MB) to: $zipHtmlPath"
    try {
        Compress-Archive -Path $oldHtmlFiles.FullName -DestinationPath $zipHtmlPath -Force -ErrorAction Stop
        Write-Host "[OK]   ZIP created: $zipHtmlPath"
    } catch {
        Write-Host "[ERROR] Failed to create reports ZIP: $($_.Exception.Message)"; exit 2
    }
    try {
        $oldHtmlFiles | Remove-Item -Force -ErrorAction Stop
        Write-Host "[OK]   Deleted original HTML files after archiving."
    } catch {
        Write-Host "[WARN] Could not delete one or more HTML files: $($_.Exception.Message)"
    }
} else {
    Write-Host "[INFO] No HTML files older than 14 days found (recursive)."
}

# === Step 1B: Archive DB backup files (failed_logins.db.bak_YYYYMMDD_HHMMSS) older than 14 days (recursive) ===
# Strict pattern: exactly "failed_logins.db.bak_" + 8 digits + "_" + 6 digits, no extension
$bakPattern = '^failed_logins\.db\.bak_\d{8}_\d{6}$'

$oldBakFiles = Get-ChildItem -Path $backupDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match $bakPattern -and $_.LastWriteTime -lt $cutoffHtml
    }

if ($oldBakFiles -and $oldBakFiles.Count -gt 0) {
    $bakSizeBytes = ($oldBakFiles | Measure-Object -Property Length -Sum).Sum
    $bakSizeMB    = if ($bakSizeBytes) { [Math]::Round($bakSizeBytes / 1MB, 2) } else { 0 }
    Write-Host "[INFO] Archiving $($oldBakFiles.Count) DB backups (~$bakSizeMB MB) to: $zipBakPath"
    try {
        Compress-Archive -Path $oldBakFiles.FullName -DestinationPath $zipBakPath -Force -ErrorAction Stop
        Write-Host "[OK]   ZIP created: $zipBakPath"
    } catch {
        Write-Host "[ERROR] Failed to create backups ZIP: $($_.Exception.Message)"; exit 3
    }
    try {
        $oldBakFiles | Remove-Item -Force -ErrorAction Stop
        Write-Host "[OK]   Deleted original DB backup files after archiving."
    } catch {
        Write-Host "[WARN] Could not delete one or more DB backup files: $($_.Exception.Message)"
    }
} else {
    Write-Host "[INFO] No DB backups (failed_logins.db.bak_*) older than 14 days found (recursive)."
}

# === Step 2A: Delete old ZIPs (> 180 days) in reportDir (recursive) ===
$oldZipsReports = Get-ChildItem -Path $reportDir -Filter *.zip -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoffZip }

if ($oldZipsReports -and $oldZipsReports.Count -gt 0) {
    $zipSizeBytes = ($oldZipsReports | Measure-Object -Property Length -Sum).Sum
    $zipSizeMB    = if ($zipSizeBytes) { [Math]::Round($zipSizeBytes / 1MB, 2) } else { 0 }
    Write-Host "[INFO] Deleting $($oldZipsReports.Count) old report ZIPs (~$zipSizeMB MB total) ..."
    try {
        $oldZipsReports | Remove-Item -Force -ErrorAction Stop
        Write-Host "[OK]   Old report ZIPs (HTML) deleted."
    } catch {
        Write-Host "[WARN] Could not delete one or more report ZIPs: $($_.Exception.Message)"
    }
} else {
    Write-Host "[INFO] No report ZIPs (HTML) older than 6 months found (recursive)."
}

# === Step 2B: Delete old ZIPs (> 180 days) in backupDir (recursive) ===
# Safety: only delete our own archive ZIPs, e.g. "ArchivedBackups_YYYY-mm-dd_HH-mm.zip"
$oldZipsBackups = Get-ChildItem -Path $backupDir -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $_.LastWriteTime -lt $cutoffZip -and $_.Name -like 'ArchivedBackups_*.zip'
    }

if ($oldZipsBackups -and $oldZipsBackups.Count -gt 0) {
    $zip2SizeBytes = ($oldZipsBackups | Measure-Object -Property Length -Sum).Sum
    $zip2SizeMB    = if ($zip2SizeBytes) { [Math]::Round($zip2SizeBytes / 1MB, 2) } else { 0 }
    Write-Host "[INFO] Deleting $($oldZipsBackups.Count) old backup ZIPs (~$zip2SizeMB MB total) ..."
    try {
        $oldZipsBackups | Remove-Item -Force -ErrorAction Stop
        Write-Host "[OK]   Old backup ZIPs (DB) deleted."
    }
    catch {
        Write-Host "[WARN] Could not delete one or more backup ZIPs: $($_.Exception.Message)"
    }
}
else {
    Write-Host "[INFO] No backup ZIPs (DB) older than 6 months found (recursive)."
}
Write-Host "[DONE] Cleaner completed."
