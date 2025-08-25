# helper.ps1

# Set global paths
$Global:InstallDbPath = Join-Path $PSScriptRoot 'installations.db'

$sqliteCandidates = @('sqlite3.exe', 'sqlite364.exe')
foreach ($candidate in $sqliteCandidates) {
    $fullPath = Join-Path $PSScriptRoot $candidate
    if (Test-Path $fullPath) {
        $Global:SqliteExe = $fullPath
        break
    }
}

if (-not $Global:SqliteExe) {
    throw "No sqlite3 executable found in $PSScriptRoot. Expected sqlite3.exe or sqlite364.exe."
}

# Define SQLite wrapper function
function Invoke-SqliteCli {
    param (
        [string]$DbFile,
        [string]$Sql,
        [switch]$Silent
    )

    # Optional: Warn if DB file doesn't exist, but don't block
    if (-not (Test-Path $DbFile)) {
        Write-Host "Database file does not exist yet: $DbFile (will be created if needed)"
    }

    if (-not (Test-Path $Global:SqliteExe)) {
        throw "SQLite executable not found: $Global:SqliteExe"
    }

    $arguments = "`"$DbFile`" `"$Sql`""
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $Global:SqliteExe
    $processInfo.Arguments = $arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    $output = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()

    # Split output into lines
    $lines = $output -split "`r?`n"

    # Filter empty lines if Silent
    if ($Silent) {
        return $lines | Where-Object { $_.Trim() -ne "" }
    }

    Write-Host "Executed SQL on $DbFile"
    return $lines
}

Write-Host "helper.ps1 loaded. SQLite path: $Global:SqliteExe"