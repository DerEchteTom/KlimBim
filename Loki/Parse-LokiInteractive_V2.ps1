Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Web

function Encode-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Web.HttpUtility]::HtmlEncode($Text)
}

# 1) Datei auswählen
$openDlg = New-Object Microsoft.Win32.OpenFileDialog
$openDlg.Title  = "Logdatei auswaehlen"
$openDlg.Filter = "Logdateien (*.log;*.txt)|*.log;*.txt|Alle Dateien (*.*)|*.*"
if (-not $openDlg.ShowDialog()) { Write-Host "Abgebrochen."; return }

# Datei laden (mit Fallback-Encoding)
$lines = Get-Content -LiteralPath $openDlg.FileName -Encoding UTF8
if (-not $lines -or $lines.Count -eq 0) {
    $lines = Get-Content -LiteralPath $openDlg.FileName -Encoding Unicode
    if (-not $lines -or $lines.Count -eq 0) {
        $lines = Get-Content -LiteralPath $openDlg.FileName -Encoding Default
    }
}

# 2) Parsing
$patternSimple = '^(?<Timestamp>\d{8}T\d{2}:\d{2}:\d{2}Z)[\t ]+(?<Severity>[A-Za-z]+)[\t ]+(?<Message>.+)$'
$patternLoki   = '^(?<Timestamp>\d{8}T\d{2}:\d{2}:\d{2}Z)\s+\S+\s+LOKI:\s+(?<Severity>\w+):(.*?MODULE:\s*(?<Module>\S+)\s+MESSAGE:\s*(?<Message>.*)|\s+(?<Message>.*))$'
$patternGerman = '^(?<Timestamp>\d{2}\.\d{2}\.\d{4}\s+\d{2}:\d{2}:\d{2})\s+(?<Severity>\w+)\s+(?:(?<Module>\S+)\s+)?(?<Message>.+)$'

function Normalize-Severity([string]$sev) {
    if ([string]::IsNullOrWhiteSpace($sev)) { return 'Info' }
    $sevLower = $sev.ToLowerInvariant()
    switch ($sevLower) {
        'warn'     { 'Warning' ; break }
        'warning'  { 'Warning' ; break }
        'alert'    { 'Alert'   ; break }
        'notice'   { 'Notice'  ; break }
        'info'     { 'Info'    ; break }
        default    { ($sevLower.Substring(0,1).ToUpper()+$sevLower.Substring(1)) }
    }
}

$parsed = @()
foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $mLoki   = [regex]::Match($line, $patternLoki)
    $mSimple = [regex]::Match($line, $patternSimple)
    $mGerman = [regex]::Match($line, $patternGerman)

    if ($mLoki.Success) {
        $sev = Normalize-Severity $mLoki.Groups['Severity'].Value
        $parsed += [PSCustomObject]@{
            Zeit      = $mLoki.Groups['Timestamp'].Value
            Stufe     = $sev
            Modul     = $mLoki.Groups['Module'].Value
            Nachricht = $mLoki.Groups['Message'].Value
        }
        continue
    }
    if ($mSimple.Success) {
        $sev = Normalize-Severity $mSimple.Groups['Severity'].Value
        $parsed += [PSCustomObject]@{
            Zeit      = $mSimple.Groups['Timestamp'].Value
            Stufe     = $sev
            Modul     = ""
            Nachricht = $mSimple.Groups['Message'].Value
        }
        continue
    }
    if ($mGerman.Success) {
        $sev = Normalize-Severity $mGerman.Groups['Severity'].Value
        $parsed += [PSCustomObject]@{
            Zeit      = $mGerman.Groups['Timestamp'].Value
            Stufe     = $sev
            Modul     = $mGerman.Groups['Module'].Value
            Nachricht = $mGerman.Groups['Message'].Value
        }
        continue
    }
    $parsed += [PSCustomObject]@{
        Zeit      = ""
        Stufe     = "Info"
        Modul     = ""
        Nachricht = $line
    }
}

# Name-Feld bestimmen
foreach ($obj in $parsed) {
    $name = ''
    $mFile = [regex]::Match($obj.Nachricht, '(?i)\bFILE:\s*([^\s]+)')
    if ($mFile.Success) {
        try { $name = [System.IO.Path]::GetFileName($mFile.Groups[1].Value) } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $mName = [regex]::Match($obj.Nachricht, '(?i)\bNAME:\s*([^\s,]+)')
        if ($mName.Success) { $name = $mName.Groups[1].Value }
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $mAny = [regex]::Match($obj.Nachricht, '\b([\w\-]+\.(?:exe|dll|sys))\b')
        if ($mAny.Success) { $name = $mAny.Groups[1].Value }
    }
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $obj.Nachricht }
    $obj | Add-Member -NotePropertyName Name -NotePropertyValue $name -Force
}

Write-Host ("Zeilen: {0} | Parsed: {1}" -f $lines.Count, $parsed.Count)
$kritisch = $parsed | Where-Object { $_.Stufe -in @('Warning','Alert') }
$rest     = $parsed | Where-Object { $_.Stufe -notin @('Warning','Alert') }
Write-Host ("Kritisch: {0} | Rest: {1}" -f $kritisch.Count, $rest.Count)

# 4) Hilfsfunktion HTML-Zeilen
function Convert-ToHtmlRows($data) {
    $tokenPattern = '(?<url>https?://[^\s<>()]+)|(?<file>\b[\w\-]+\.(?:exe|dll|sys)\b)|(?<score>(?:SCORE:|PATCHED:\s*))(?<scoreval>\d+)'
    $badgeStyle = "background-color:#e6f3ff"
    $groups = $data | Group-Object -Property Stufe, Modul, Name

    foreach ($g in $groups) {
        $zeiten = $g.Group.Zeit | Sort-Object
        $zeitInfo = if ($zeiten.Count -gt 1) { "$($zeiten[0]) ... $($zeiten[-1])" } else { $zeiten[0] }
        $zeitHtml = "<span style='white-space:nowrap'>" + [System.Web.HttpUtility]::HtmlEncode($zeitInfo) + "</span>"

        $sevHtml  = "<strong>" + [System.Web.HttpUtility]::HtmlEncode($g.Group[0].Stufe) + "</strong>"
        $modHtml  = [System.Web.HttpUtility]::HtmlEncode($g.Group[0].Modul)
        $nameHtml = [System.Web.HttpUtility]::HtmlEncode($g.Group[0].Name)

        $render = {
            param([string]$text)
            if ($null -eq $text) { return "" }
            $sb = New-Object System.Text.StringBuilder
            $idx = 0
            $matches = [System.Text.RegularExpressions.Regex]::Matches($text, $tokenPattern)
            foreach ($m in $matches) {
            if ($m.Index -gt $idx) {
            $before = $text.Substring($idx, $m.Index - $idx)
            [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($before))
            }
            if ($m.Groups['url'].Success) {
            $u = $m.Groups['url'].Value
            [void]$sb.Append("<a href='" + [System.Web.HttpUtility]::HtmlAttributeEncode($u) + "' target='_blank'>" +
                             [System.Web.HttpUtility]::HtmlEncode($u) + "</a>")
            }
            elseif ($m.Groups['file'].Success) {
            $f = $m.Groups['file'].Value
            [void]$sb.Append("<span style='$badgeStyle'>" + [System.Web.HttpUtility]::HtmlEncode($f) + "</span>")
            }
            elseif ($m.Groups['score'].Success) {
            $label = $m.Groups['score'].Value
            $val   = $m.Groups['scoreval'].Value
            [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($label) + "<strong>" +
                             [System.Web.HttpUtility]::HtmlEncode($val) + "</strong>")
        }
        $idx = $m.Index + $m.Length
    }
    if ($idx -lt $text.Length) {
        $tail = $text.Substring($idx)
        [void]$sb.Append([System.Web.HttpUtility]::HtmlEncode($tail))
    }
    $sb.ToString()
}

        # Einzigartige Links sammeln
        $allLinks = @()
        foreach ($msg in $g.Group.Nachricht) {
            $linkMatches = [regex]::Matches($msg, 'https?://[^\s<>()]+')
            foreach ($linkMatch in $linkMatches) {
                if (-not $allLinks.Contains($linkMatch.Value)) { $allLinks += $linkMatch.Value }
            }
        }

        # SCORE/PATCHED ermitteln
        $metricSummaries = @()
        foreach ($label in @('SCORE','PATCHED')) {
            $vals = @()
            foreach ($msg in $g.Group.Nachricht) {
                $metricMatch = [regex]::Match($msg, ($label + ':\s*(\d+)'), 'IgnoreCase')
                if ($metricMatch.Success) { $vals += [int]$metricMatch.Groups[1].Value }
            }
            if ($vals.Count -gt 0) {
                $min = ($vals | Measure-Object -Minimum).Minimum
                $max = ($vals | Measure-Object -Maximum).Maximum
             if ($min -eq $max) {
                $metricSummaries += "${label}: $min"
            } else {
                $metricSummaries += "${label}: $min-$max"
            }
        }
        $metricText = if ($metricSummaries.Count -gt 0) { " (" + ($metricSummaries -join ' | ') + ")" } else { "" }

        # Pfad extrahieren (nur erster)
        $pfade = @()
        foreach ($msg in $g.Group.Nachricht) {
            $pMatch = [regex]::Match($msg, 'PATH:\s*([^\s]+)')
            if ($pMatch.Success -and -not $pfade.Contains($pMatch.Groups[1].Value)) {
                $pfade += $pMatch.Groups[1].Value
            }
        }
    }
        # Kopfzeile (kompakt)
        $headParts = @()
        if ($pfade.Count -gt 0) { $headParts += [System.Web.HttpUtility]::HtmlEncode($pfade[0]) }
        $headParts += ("{0} Treffer{1}" -f $g.Group.Count, $metricText)
        foreach ($link in $allLinks) {
            $headParts += "<a href='$link' target='_blank'>" + [System.Web.HttpUtility]::HtmlEncode($link) + "</a>"
        }
        $headHtml = ($headParts -join "<br>")

        # Detailblock
        $detailsHtml = ($g.Group | ForEach-Object { & $render $_.Nachricht }) -join "<br>"

        "<tr><td>$zeitHtml</td>
             <td class='sev-$($g.Group[0].Stufe)'>$sevHtml</td>
             <td>$modHtml</td>
             <td>$nameHtml</td>
             <td>$headHtml<br>
                 <a href='#' onclick='toggleDetails(this);return false;'>Details anzeigen</a>
                 <div class='details' style='display:none;'>$detailsHtml</div>
             </td></tr>"
    } -join "`r`n"
}

# 5) CSS + JS
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
 .details{margin-top:4px;padding:4px;background:#f9f9f9;border:1px dashed #ccc}
 a{color:#0645ad;text-decoration:none}
 a:hover{text-decoration:underline}
</style>
<script>
function toggleDetails(link) {
  var div = link.nextElementSibling;
  if (!div) return;
  if (div.style.display === "none" || div.style.display === "") {
    div.style.display = "block";
    link.textContent = "Details ausblenden";
  } else {
    div.style.display = "none";
    link.textContent = "Details anzeigen";
  }
}
</script>
"@

# 6) HTML zusammensetzen
$html = @"
<!DOCTYPE html>
<html lang="de">
<head><meta charset="utf-8"><title>Log Auswertung</title>$style</head>
<body>
<h2>Kritische Eintraege (Warning / Alert)</h2>
<table>
<thead><tr><th>Zeit</th><th>Severity</th><th>Modul</th><th>Name</th><th>Message</th></tr></thead>
<tbody>
$(Convert-ToHtmlRows $kritisch)
</tbody>
</table>

<h2>Alle uebrigen Eintraege</h2>
<table>
<thead><tr><th>Zeit</th><th>Severity</th><th>Modul</th><th>Name</th><th>Message</th></tr></thead>
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