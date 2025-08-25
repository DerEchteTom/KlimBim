# Fehlerbehandlung aktivieren
$ErrorActionPreference = "Stop"

function Show-Progress {
    param ([string]$message)
    Write-Host ""
    Write-Host ">>> $message"
    Start-Sleep -Seconds 1
}

Show-Progress "Starte Windows Update-Skript"

try {
    Show-Progress "Setze Execution Policy"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

    Show-Progress "Installiere NuGet Provider bei Bedarf"
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Confirm:$false
    }

    Show-Progress "Pruefe Repository PSGallery"
    $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if (-not $repo) {
        Show-Progress "Registriere Standard-PSGallery"
        Register-PSRepository -Default
        $repo = Get-PSRepository -Name PSGallery
    }

    if ($repo.InstallationPolicy -ne 'Trusted') {
        Show-Progress "Setze PSGallery als vertrauenswuerdig"
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    Show-Progress "Installiere Modul PSWindowsUpdate"
    Install-Module -Name PSWindowsUpdate -Repository PSGallery -Force -AllowClobber -Confirm:$false

    Show-Progress "Importiere Modul"
    if (-not (Get-Module -Name PSWindowsUpdate)) {
        Import-Module PSWindowsUpdate -ErrorAction Stop
    }

    Show-Progress "Suche nach Updates, dies kann einige Zeit in Anspruch nehmen"
    $updates = Get-WindowsUpdate -MicrosoftUpdate

    if (-not $updates -or $updates.Count -eq 0) {
        Show-Progress "Keine Updates gefunden. Skript beendet."
        Show-Progress "Press any key..."
        [System.Console]::ReadKey($true)
        return
    }

    Show-Progress "Updates gefunden: $($updates.Count). Installation startet"
    Install-WindowsUpdate -MicrosoftUpdate -AcceptAll

    # GUI-Fenster nur anzeigen, wenn Updates installiert wurden
    Show-Progress "Pruefe ob Neustart erforderlich ist"
    $rebootRequired = ($updates | Where-Object { $_.RebootRequired -eq $true }).Count -gt 0

    Add-Type -AssemblyName System.Windows.Forms

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Update abgeschlossen"
    $form.Size = New-Object System.Drawing.Size(420,180)
    $form.StartPosition = "CenterScreen"
    $form.Topmost = $true

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(20,20)
    $label.Font = New-Object System.Drawing.Font("Arial",12)

    if ($rebootRequired) {
        $label.Text = "Ein Neustart ist erforderlich. Bitte waehlen Sie eine Option."
    } else {
        $label.Text = "Updates wurden installiert. Kein Neustart erforderlich."
    }

    $form.Controls.Add($label)

    if ($rebootRequired) {
        $buttonNow = New-Object System.Windows.Forms.Button
        $buttonNow.Text = "Jetzt neu starten"
        $buttonNow.Size = New-Object System.Drawing.Size(120,30)
        $buttonNow.Location = New-Object System.Drawing.Point(20,80)
        $buttonNow.Add_Click({
            $form.Close()
            Restart-Computer -Force
        })
        $form.Controls.Add($buttonNow)

        $buttonCancel = New-Object System.Windows.Forms.Button
        $buttonCancel.Text = "Abbrechen"
        $buttonCancel.Size = New-Object System.Drawing.Size(120,30)
        $buttonCancel.Location = New-Object System.Drawing.Point(160,80)
        $buttonCancel.Add_Click({
            $form.Close()
        })
        $form.Controls.Add($buttonCancel)
    } else {
        $buttonOK = New-Object System.Windows.Forms.Button
        $buttonOK.Text = "OK"
        $buttonOK.Size = New-Object System.Drawing.Size(120,30)
        $buttonOK.Location = New-Object System.Drawing.Point(20,80)
        $buttonOK.Add_Click({
            $form.Close()
        })
        $form.Controls.Add($buttonOK)
    }

    $form.ShowDialog()
}
catch {
    Write-Host ""
    Write-Host ">>> Fehler beim GUI-Fenster: $($_.Exception.Message)"
}