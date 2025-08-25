# === Block 1: Configuration ===
$DebugMode       = $true
$TimeWindowHours = 48
$TimeCutoff      = (Get-Date).AddHours(-$TimeWindowHours)
$FilterList      = @("microsoft","windows","office365","apache tomcat","apache HTTP","vmware","linux kernel","google chrome","firefox","Linux Distributionen")
$RegexFilter     = ($FilterList | ForEach-Object { [Regex]::Escape($_) }) -join "|"
$OutputPath      = "$PSScriptRoot\security_feed.html"
$HtmlContent     = @()

function MatchesFilter {
    param ($text)
    return $text -match $RegexFilter
}

$HtmlContent += "<h1>Security Feed Overview</h1>"

# === Block 2: CISA KEV ===
if ($DebugMode) { Write-Host "Fetching CISA KEV..." }

$CisaBlock = @()
$CisaBlock += "<h2>CISA KEV - Focus on actively exploited vulnerabilities</h2>"
$CisaBlock += "<h3>CVE Entries</h3><ul>"
$CisaCveList = @()

try {
    $json = Invoke-RestMethod -Uri "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
    foreach ($v in $json.vulnerabilities) {
        $added  = [datetime]$v.dateAdded
        $cveID  = $v.cveID
        $vendor = $v.vendorProject
        $name   = $v.vulnerabilityName

        if (($added -gt $TimeCutoff) -and (MatchesFilter $vendor -or MatchesFilter $name)) {
            if (-not $cveID)  { $cveID  = "Unknown-CVE" }
            if (-not $vendor) { $vendor = "Unknown Vendor" }
            if (-not $name)   { $name   = "Unnamed Vulnerability" }

            $title = "$vendor - $name ($cveID)"
            $url   = "https://nvd.nist.gov/vuln/detail/$cveID"

            $CisaBlock += "<li><a href='$url' target='_blank'>$title</a> - $added</li>"
            $CisaCveList += $cveID
        }
    }
}
catch {
    Write-Warning "CISA KEV fetch failed: $_"
}
$CisaBlock += "</ul>"

if (($CisaBlock -join "`n") -match "<li>") {
    $HtmlContent += $CisaBlock
}

# === Block 3: NVD Feed ===
if ($DebugMode) { Write-Host "Fetching NVD Feed..." }

$NvdBlock = @()
$NvdBlock += "<h2>NVD Feed - Overview of newly published vulnerabilities</h2>"
$NvdBlock += "<h3>CVE Entries</h3><ul>"

try {
    $gzUrl    = "https://nvd.nist.gov/feeds/json/cve/1.1/nvdcve-1.1-recent.json.gz"
    $gzFile   = "$PSScriptRoot\nvd_recent.json.gz"
    $jsonFile = "$PSScriptRoot\nvd_recent.json"

    Invoke-WebRequest -Uri $gzUrl -OutFile $gzFile
    $inStream  = [IO.File]::OpenRead($gzFile)
    $outStream = [IO.File]::Create($jsonFile)
    $gzip      = New-Object IO.Compression.GzipStream($inStream, [IO.Compression.CompressionMode]::Decompress)
    $gzip.CopyTo($outStream)
    $gzip.Close(); $inStream.Close(); $outStream.Close()

    $text = Get-Content -Path $jsonFile -Raw
    $nvd  = $text | ConvertFrom-Json

    $filtered = $nvd.CVE_Items | Where-Object {
        $published = [datetime]$_.publishedDate
        $cveId     = $_.cve.CVE_data_meta.ID
        ($published -gt $TimeCutoff) -and
        (
            ($_.cve.affects.vendor.vendor_name -match $RegexFilter) -or
            ($_.cve.description.description_data[0].value -match $RegexFilter)
        ) -and
        (-not $CisaCveList -contains $cveId)
    }

    foreach ($item in $filtered | Sort-Object {[datetime]$_.publishedDate} -Descending | Select-Object -First 10) {
        $cveId   = $item.cve.CVE_data_meta.ID
        $summary = $item.cve.description.description_data[0].value
        $link    = "https://nvd.nist.gov/vuln/detail/$cveId"
        $NvdBlock += "<li><a href='$link' target='_blank'>$cveId</a>: $summary</li>"
    }

    Remove-Item $gzFile, $jsonFile -Force
}
catch {
    Write-Warning "NVD fetch failed: $_"
}
$NvdBlock += "</ul>"

if (($NvdBlock -join "`n") -match "<li>") {
    $HtmlContent += $NvdBlock
}

# === Block 4: Debian DSA ===
$DebianBlock = @()
$DebianBlock += "<h2>Debian DSA - Security advisories from Debian</h2>"
$DebianBlock += "<h3>CVE Entries</h3><ul>"

try {
    $feed = [xml](Invoke-WebRequest -Uri "https://www.debian.org/security/dsa.rdf" -UseBasicParsing).Content
    foreach ($item in $feed.RDF.item) {
        $date  = [datetime]$item.date
        $title = $item.title
        $link  = $item.link

        if (($date -gt $TimeCutoff) -and (MatchesFilter $title)) {
            $DebianBlock += "<li><a href='$link' target='_blank'>$title</a> - $date</li>"
        }
    }
}
catch {
    Write-Warning "Debian DSA fetch failed: $_"
}
$DebianBlock += "</ul>"

if (($DebianBlock -join "`n") -match "<li>") {
    $HtmlContent += $DebianBlock
}

# === Block 5: Heise Security ===
$HeiseBlock = @()
$HeiseBlock += "<h2>Heise Security - News from Heise.de</h2>"
$HeiseBlock += "<h3>Security News</h3><ul>"

try {
    $feed = [xml](Invoke-WebRequest -Uri "https://www.heise.de/security/rss/news-atom.xml" -UseBasicParsing).Content
    foreach ($entry in $feed.feed.entry) {
        $updated = [datetime]$entry.updated
        $title   = $entry.title.'#text'
        $link    = $entry.link.href

        if (($updated -gt $TimeCutoff) -and (MatchesFilter $title)) {
            $HeiseBlock += "<li><a href='$link' target='_blank'>$title</a> - $updated</li>"
        }
    }
}
catch {
    Write-Warning "Heise fetch failed: $_"
}
$HeiseBlock += "</ul>"

# Nur einfügen, wenn mindestens ein Eintrag vorhanden ist
if (($HeiseBlock -join "`n") -match "<li>") {
    $HtmlContent += $HeiseBlock
}

# === Block 6: BSI CERT ===
$BsiBlock = @()
$BsiBlock += "<h2>BSI CERT - Advisories from German CERT</h2>"
$BsiBlock += "<h3>Security News</h3><ul>"

try {
    $feed = [xml](Invoke-WebRequest -Uri "https://wid.cert-bund.de/content/public/securityAdvisory/rss" -UseBasicParsing).Content
    foreach ($item in $feed.rss.channel.item) {
        $pubDate = [datetime]$item.pubDate
        $title   = $item.title
        $link    = $item.link

        if (($pubDate -gt $TimeCutoff) -and (MatchesFilter $title)) {
            $BsiBlock += "<li><a href='$link' target='_blank'>$title</a> - $pubDate</li>"
        }
    }
}
catch {
    Write-Warning "BSI CERT fetch failed: $_"
}
$BsiBlock += "</ul>"

# Nur einfügen, wenn mindestens ein Eintrag vorhanden ist
if (($BsiBlock -join "`n") -match "<li>") {
    $HtmlContent += $BsiBlock
}

# === Block 7: GitHub Advisory ===
$GitHubBlock = @()
$GitHubBlock += "<h2>GitHub Advisory - Vulnerability alerts from GitHub</h2>"
$GitHubBlock += "<h3>Security News</h3><ul>"

try {
    $headers = @{ "User-Agent" = "PowerShell" }
    $advisories = Invoke-WebRequest -Uri "https://api.github.com/advisories?per_page=20" -Headers $headers -UseBasicParsing | ConvertFrom-Json
    foreach ($adv in $advisories) {
        $summary = $adv.summary
        $url     = $adv.html_url

        if (MatchesFilter $summary) {
            $GitHubBlock += "<li><a href='$url' target='_blank'>$summary</a></li>"
        }
    }
}
catch {
    Write-Warning "GitHub Advisory fetch failed: $_"
}
$GitHubBlock += "</ul>"

# Nur hinzufügen, wenn mindestens ein <li> enthalten ist
if (($GitHubBlock -join "`n") -match "<li>") {
    $HtmlContent += $GitHubBlock
}


# === Block 8: HTML-Rahmen mit Design ===
# HTML-Kopf und CSS-Design
$Header = @"
<html>
<head>
<meta charset='UTF-8'>
<title>Security messages</title>
<style>
  body { font-family: Arial, sans-serif; background-color: #f9f9f9; color: #333; margin: 20px; }
  h1 { color: #1a4d8f; border-bottom: 2px solid #ccc; padding-bottom: 6px; }
  h2 { color: #1a4d8f; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin-top: 30px; }
  h3 { color: #2e6da4; margin-top: 20px; }
  ul { padding-left: 20px; }
  li { margin-bottom: 6px; line-height: 1.5; }

  /* Links: Standard wie normaler Text */
  a {
    color: inherit;
    text-decoration: none;
    transition: color 0.2s ease, text-decoration 0.2s ease;
  }

  /* Links beim Hover: sichtbar als Link */
  a:hover {
    color: #0066cc;
    text-decoration: underline;
  }
    a[target="_blank"]::after {
  content: " <-LINK ";
  font-size: 0.9em;
}

</style>
</head>
<body>
"@


# === Block 9: HTML-Datei ins \result schreiben ===

# Zielverzeichnis relativ zum Skript
$ResultDir = Join-Path $PSScriptRoot "result"
if (-not (Test-Path $ResultDir)) {
    New-Item -Path $ResultDir -ItemType Directory | Out-Null
}

# Zielpfad für die HTML-Datei
$OutputPath = Join-Path $ResultDir "security_feed.html"

# Gesamten HTML-Inhalt zusammenfügen
$FullHtml = $Header + ($HtmlContent -join "`n") + $Footer

# Dynamischer Dateiname mit Datum und Uhrzeit
$Timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$FileName    = "security_feed_$Timestamp.html"
$OutputPath  = Join-Path $ResultDir $FileName

# Gesamten HTML-Inhalt zusammenfügen und schreiben
$FullHtml | Out-File -FilePath $OutputPath -Encoding UTF8

# Erfolgsmeldung (optional)
if ($DebugMode) {
    Write-Host "HTML successfully created:`n$OutputPath"
}

# UNC-Link zur HTML-Datei (statt Anhang)
$HtmlLink = "\\ttbvmdc02\cve_result\$FileName"
$Body     = "New CVE entries have been found.`nYou can view the report here:`n$HtmlLink"

# === Block 10: E-Mail-Versand mit Logging und Link ===

# SMTP-Konfiguration (ohne Authentifizierung, ohne SSL)
$SmtpServer = "172.16.30.21"
$SmtpPort   = 25
$From       = "noreply@technoteam.de"
$To         = "thomas.schmidt@technoteam.de"
$Subject    = "New Security Information"

# Steuerung: E-Mail-Versand und Logging aktivieren/deaktivieren
$SendEmail  = $true
$EnableLog  = $true

# Log-Dateipfad (relativ zum Skript)
$LogDir  = Join-Path $PSScriptRoot "result"
$LogFile = Join-Path $LogDir "SecurityReport.log"

# Funktion zum Schreiben ins Log
function Write-Log {
    param (
        [string]$Message
    )
    if ($EnableLog) {
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$Timestamp - $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

# Prüfung: Gibt es neue CVEs?
$HasNewCves = ($HtmlContent -join "`n") -match "<li>"
Write-Log "SendEmail=$SendEmail, HasNewCves=$HasNewCves"

# Nur senden, wenn aktiviert und neue CVEs vorhanden sind
if ($SendEmail -and $HasNewCves) {
    try {
        Send-MailMessage -From $From -To $To -Subject $Subject -Body $Body `
            -SmtpServer $SmtpServer -Port $SmtpPort -BodyAsHtml:$false

        Write-Host "E-Mail successfully sent."
        Write-Log "E-Mail successfully sent to $To"
    }
    catch {
        Write-Warning "Problem sending E-Mail: $_"
        Write-Log "ERROR: Problem sending E-Mail: $($_.Exception.Message)"
    }
}
elseif ($SendEmail -and -not $HasNewCves) {
    Write-Host "No new CVEs - no E-Mail sent."
    Write-Log "No new CVEs - E-Mail not sent."
}
else {
    Write-Log "E-Mail sending disabled."
}