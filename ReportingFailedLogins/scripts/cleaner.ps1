# === Settings ===
. "$PSScriptRoot\..\Config-Helper.ps1"
$reportDir = Get-ReportDirPath
$zipName   = "ArchivedReports_{0}.zip" -f (Get-Date -Format "yyyy-MM-dd_HH-mm")
$zipPath   = Join-Path $reportDir $zipName

# === Step 1: HTML-Dateien älter als 14 Tage archivieren ===
$oldHtmlFiles = Get-ChildItem -Path $reportDir -Filter *.html | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-14)
}

if ($oldHtmlFiles.Count -gt 0) {
    Write-Host "Archiviere $($oldHtmlFiles.Count) HTML-Dateien in: $zipPath"

    # ZIP erstellen
    Compress-Archive -Path $oldHtmlFiles.FullName -DestinationPath $zipPath -Force

    # Originaldateien löschen
    $oldHtmlFiles | Remove-Item -Force
} else {
    Write-Host "Keine HTML-Dateien älter als 14 Tage gefunden."
}

# === Step 2: ZIP-Dateien älter als 180 Tage löschen ===
$oldZips = Get-ChildItem -Path $reportDir -Filter *.zip | Where-Object {
    $_.LastWriteTime -lt (Get-Date).AddDays(-180)
}

if ($oldZips.Count -gt 0) {
    Write-Host "Lösche $($oldZips.Count) alte ZIP-Dateien..."
    $oldZips | Remove-Item -Force
} else {
    Write-Host "Keine ZIP-Dateien älter als 6 Monate gefunden."
}