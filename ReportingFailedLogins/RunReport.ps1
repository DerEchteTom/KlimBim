# RunReport.ps1
$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ScriptDir = Join-Path $BaseDir "scripts"
$LogFile = Join-Path $BaseDir "RunReport.log"

# Scripts = @("FailedLogons.ps1", "Enrichment.ps1", "Exporter.ps1")
$Scripts = @("FailedLogons.ps1", "Enrichment.ps1", "Exporter.ps1", "Send.ps1", "Exporter_incl.ps1", "Send_incl.ps1", "cleaner.ps1")

Add-Content $LogFile "`n=== Report Execution Started ==="
Add-Content $LogFile "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"

foreach ($script in $Scripts) {
    $scriptPath = Join-Path $ScriptDir $script
    Write-Host "Running $script..."
    Add-Content $LogFile "[${script}] Starting"

    try {
        $output = powershell.exe -ExecutionPolicy Bypass -File "`"$scriptPath`""
        Add-Content $LogFile $output
        Write-Host "SUCCESS: $script completed." -ForegroundColor Green
        Add-Content $LogFile "[${script}] Completed"
    } catch {
        Write-Host "EXCEPTION in ${script}: $($_)" -ForegroundColor Red
        Add-Content $LogFile "[${script}] EXCEPTION: $($_)"
    }

    Add-Content $LogFile ""
}

Add-Content $LogFile "=== Report Execution Finished ===`n"
Write-Host "All done."