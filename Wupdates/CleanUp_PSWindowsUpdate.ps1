# Setze Execution Policy temporär
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

# Pruefe Administratorrechte
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Dieses Skript muss als Administrator ausgefuehrt werden."
    exit 1
}

# Beende andere PowerShell-Prozesse, um Sperren zu vermeiden
Get-Process -Name powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $PID } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force
            Write-Host "Beende PowerShell-Prozess mit ID $($_.Id)"
        }
        catch {
            Write-Warning "Konnte Prozess $($_.Id) nicht beenden: $_"
        }
    }

# Fehlerbehandlung
$ErrorActionPreference = "Stop"

Write-Host "Starte Cleanup..."

# Modul entladen, falls aktiv
try {
    Write-Host "Entlade PSWindowsUpdate-Modul..."
    Remove-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Modul konnte nicht entladen werden: $_"
}

# Modul deinstallieren
try {
    Write-Host "Deinstalliere PSWindowsUpdate-Modul..."
    Get-InstalledModule -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
        Uninstall-Module -Force
}
catch {
    Write-Warning "Modul konnte nicht deinstalliert werden: $_"
}

# Modulverzeichnis loeschen
$modPath = "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate"
if (Test-Path $modPath) {
    try {
        Write-Host "Loesche Modulverzeichnis $modPath..."
        Remove-Item -Path $modPath -Recurse -Force
    }
    catch {
        Write-Warning "Modulverzeichnis konnte nicht geloescht werden: $_"
    }
}

# NuGet-Dateien loeschen (Provider kann nicht direkt deinstalliert werden)
$nugetPaths = @(
    "$env:ProgramFiles\PackageManagement\ProviderAssemblies\nuget",
    "$env:LOCALAPPDATA\PackageManagement\ProviderAssemblies\nuget"
)
foreach ($path in $nugetPaths) {
    if (Test-Path $path) {
        try {
            Write-Host "Loesche NuGet-Dateien in $path..."
            Remove-Item -Path $path -Recurse -Force
        }
        catch {
            Write-Warning "NuGet-Dateien konnten nicht geloescht werden: $_"
        }
    }
}

# PSGallery-Repository zuruecksetzen
try {
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($repo) {
        Write-Host "Setze PSGallery auf Untrusted..."
        Set-PSRepository -Name PSGallery -InstallationPolicy Untrusted

        Write-Host "Unregister PSGallery..."
        Unregister-PSRepository -Name PSGallery -ErrorAction SilentlyContinue

        Write-Host "Registere PSGallery neu..."
        Register-PSRepository -Default
    } else {
        Write-Host "PSGallery nicht gefunden. Registere neu..."
        Register-PSRepository -Default
    }
}
catch {
    Write-Warning "PSGallery konnte nicht zurueckgesetzt werden: $_"
}

Write-Host "Cleanup abgeschlossen."