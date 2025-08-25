Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web

function Encode-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Web.HttpUtility]::HtmlEncode($Text)
}

# 1) Datei auswählen
$openDlg = New-Object Microsoft.Win32.OpenFileDialog
$openDlg.Title  = "Logdatei auswählen"
$openDlg.Filter = "Logdateien (*.log;*.txt)|*.log;*.txt|Alle Dateien (*.*)|*.*"
if (-not $openDlg.ShowDialog()) { Write-Host "Abgebrochen."; return }

$lines = Get-Content -LiteralPath $openDlg.FileName -Encoding UTF8

# 2) Parsing
$patternSimple = '^(?<Timestamp>\d{8}T\d{2}:\d{2}:\d{2}Z)[\t ]+(?<Severity>[A-Za-z]+)[\t ]+(?<Message>.+)$'
$patternLoki   = '^(?<Timestamp>\d{8}T\d{2}:\d{2}:\d{2}Z)\s+\S+\s+LOKI:\s+(?<Severity>\w+):(.*?MODULE:\s*(?<Module>\S+)\s+MESSAGE:\s*(?<Message>.*)|\s+(?<Message>.*))$'

$parsed = @()
foreach ($line in $lines) {
    if ($line -match $patternLoki) {
        $parsed += [PSCustomObject]@{
            Zeit      = $Matches['Timestamp']
            Stufe     = $Matches['Severity']
            Modul     = $Matches['Module']
            Nachricht = $Matches['Message']
        }
    }
    elseif ($line -match $patternSimple) {
        $parsed += [PSCustomObject]@{
            Zeit      = $Matches['Timestamp']
            Stufe     = $Matches['Severity']
            Modul     = ""
            Nachricht = $Matches['Message']
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($line)) {
        $parsed += [PSCustomObject]@{
            Zeit      = ""
            Stufe     = "Info"
            Modul     = ""
            Nachricht = $line
        }
    }
}

# 3) Aufteilen in kritisch / rest
$kritisch = $parsed | Where-Object { $_.Stufe -in @('Warning','Alert') }
$rest     = $parsed | Where-Object { $_.Stufe -notin @('Warning','Alert') }

# 4) Hilfsfunktion fuer HTML-Zeilen (vereinfacht, robuste Einfaerbung)
function Convert-ToHtmlRows($data) {

    # Token-Erkennung: URL, Dateiname, SCORE
    $tokenPattern = '(?<url>https?://[^\s<>()]+)|(?<file>\b[\w\-]+\.(?:exe|dll|sys)\b)|(?<score>SCORE:\s*)(?<scoreval>\d+)'

    foreach ($item in $data) {

        # Zeit menschenlesbar + nicht umbrechbar
        $zeitHtml = ""
        if ($item.Zeit -match '^(?<Year>\d{4})(?<Month>\d{2})(?<Day>\d{2})T(?<Hour>\d{2}):(?<Minute>\d{2}):(?<Second>\d{2})Z$') {
            try {
                $dt = Get-Date -Year $Matches.Year -Month $Matches.Month -Day $Matches.Day -Hour $Matches.Hour -Minute $Matches.Minute -Second $Matches.Second -Format "dd.MM.yyyy HH:mm:ss"
                $zeitHtml = "<span style='white-space:nowrap'>" + [System.Web.HttpUtility]::HtmlEncode($dt) + "</span>"
            } catch {
                $zeitHtml = "<span style='white-space:nowrap'>" + [System.Web.HttpUtility]::HtmlEncode($item.Zeit) + "</span>"
            }
        } else {
            $zeitHtml = "<span style='white-space:nowrap'>" + [System.Web.HttpUtility]::HtmlEncode($item.Zeit) + "</span>"
        }

        # Lokale Render-Funktion: baut sicheres HTML mit einfacher Einfaerbung
        $render = {
            param([string]$text)

            if ($null -eq $text) { return "" }
            $sb = New-Object System.Text.StringBuilder
            $idx = 0
            $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $tokenPattern)

            foreach ($m in $matches) {
                # vor dem Treffer
                if ($m.Index -gt $idx) {
                    $before = $text.Substring($idx, $m.Index - $idx)
                    [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($before))
                }

                if ($m.Groups['url'].Success) {
                    $u = $m.Groups['url'].Value
                    [void]$sb.Append("<a href='" + $u + "' target='_blank'>" + [System.Web.HttpUtility]::HtmlEncode($u) + "</a>")
                }
                elseif ($m.Groups['file'].Success) {
                    $f = $m.Groups['file'].Value
                    # einfache Einfaerbung (hellblau)
                    [void]$sb.Append("<span style='background-color:#e6f3ff'>" + [System.Web.HttpUtility]::HtmlEncode($f) + "</span>")
                }
                elseif ($m.Groups['score'].Success) {
                    $label = $m.Groups['score'].Value
                    $val   = $m.Groups['scoreval'].Value
                    [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($label) + "<strong>" + [System.Web.HttpUtility]::HtmlEncode($val) + "</strong>")
                }

                $idx = $m.Index + $m.Length
            }

            # Rest anhaengen
            if ($idx -lt $text.Length) {
                $tail = $text.Substring($idx)
                [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($tail))
            }

            $sb.ToString()
        }

        # Modul- und Message-HTML erzeugen
        $modHtml = & $render ($item.Modul)
        $msgHtml = & $render ($item.Nachricht)

        # Severity fett
        $sevHtml = "<strong>" + [System.Web.HttpUtility]::HtmlEncode($item.Stufe) + "</strong>"

        "<tr><td>$zeitHtml</td><td class='sev-$($item.Stufe)'>$sevHtml</td><td>$modHtml</td><td>$msgHtml</td></tr>"
    } -join "`r`n"
}

# 5) CSS-Style
$style = @"
<style>
 body{font-family:Segoe UI,Arial,sans-serif;background:#fafafa;color:#222;margin:16px}
 table{border-collapse:collapse;width:100%}
 th,td{border:1px solid #ddd;padding:6px 8px;font-size:13px;vertical-align:top}
 th{background:#f0f0f0;text-align:left}
 tr:nth-child(even){background:#fcfcfc}
 .sev-Info{color:#0366d6}
 .sev-Notice{color:#2b7a0b}
 .sev-Warning{color:#b58900}
 .sev-Alert{color:#b00020;font-weight:bold}
</style>
"@

# 6) HTML erstellen
$html = @"
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><title>Log Auswertung</title>$style</head>
<body>
<h2>Kritische Eintraege (Warning / Alert)</h2>
<table>
<thead><tr><th>Zeit</th><th>Severity</th><th>Modul</th><th>Message</th></tr></thead>
<tbody>
$(Convert-ToHtmlRows $kritisch)
</tbody>
</table>

<h2>Alle uebrigen Eintraege</h2>
<table>
<thead><tr><th>Zeit</th><th>Severity</th><th>Modul</th><th>Message</th></tr></thead>
<tbody>
$(Convert-ToHtmlRows $rest)
</tbody>
</table>
</body>
</html>
"@

# 7) Speichern
$saveDlg = New-Object Microsoft.Win32.SaveFileDialog
$saveDlg.Title      = "HTML speichern"
$saveDlg.Filter     = "HTML-Dateien (*.html)|*.html"
$saveDlg.DefaultExt = "html"
$saveDlg.FileName   = ([System.IO.Path]::GetFileNameWithoutExtension($openDlg.FileName) + "_auswertung.html")

if ($saveDlg.ShowDialog()) {
    [System.IO.File]::WriteAllText($saveDlg.FileName, $html, [System.Text.Encoding]::UTF8)
    Write-Host "Gespeichert: $($saveDlg.FileName)"
}