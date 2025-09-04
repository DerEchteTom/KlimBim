# SecurityReport.ps1

# ===========================
# START: Letzten Stand laden
# ===========================
$stateFile = ".\project_state.json"

if (Test-Path $stateFile) {
    $lastState = Get-Content $stateFile -Raw | ConvertFrom-Json
    Write-Host "Letzter Stand vom $($lastState.Timestamp):" -ForegroundColor Cyan
    Write-Host "Feeds gesamt: $($lastState.FeedCountTotal)"
    Write-Host "Nach Cutoff: $($lastState.FeedCountAfterCutoff)"
    Write-Host "Nach Filter: $($lastState.FeedCountFiltered)"
    Write-Host "Cutoff: $($lastState.Cutoff)"
    Write-Host "Keywords: $($lastState.Keywords -join ', ')"
}

# =====================================================
# Block 1: Quellenliste
# =====================================================
$sources = @(
    @{ Name = 'CISA KEV'; Url = 'https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json'; Type = 'autodetect' },
    @{ Name = 'Debian DSA'; Url = 'https://www.debian.org/security/dsa.rdf'; Type = 'autodetect' },
    @{ Name = 'Heise Security'; Url = 'https://www.heise.de/security/rss/news-atom.xml'; Type = 'autodetect' },
    @{ Name = 'BSI CERT-SEC'; Url = 'https://wid.cert-bund.de/content/public/securityAdvisory/rss'; Type = 'autodetect' },
    @{ Name = 'BSI BuergerCERT'; Url = 'https://wid.cert-bund.de/content/public/buergercert/rss'; Type = 'autodetect' },
    @{ Name = 'BSI CSW'; Url = 'https://www.bsi.bund.de/SiteGlobals/Functions/RSSFeed/RSSNewsfeed/RSSNewsfeed_CSW.xml'; Type = 'autodetect' },
    @{ Name = 'GitHub Advisory'; Url = 'https://api.github.com/advisories?per_page=60'; Type = 'autodetect' }
)

# =====================================================
# Block 2: Format-Erkennung & JSON-KompatibilitAet
# =====================================================

function Sniff-Format {
    param($res)
    if (-not $res) { return $null }

    $ct = ($res.Headers.'Content-Type' | Out-String).ToLowerInvariant()
    $body = $res.Content.TrimStart()

    if ($ct -match 'json' -or $body.StartsWith('{') -or $body.StartsWith('[')) { return 'json' }
    if ($ct -match 'rdf' -or $body -match '<rdf:RDF') { return 'rdf' }
    if ($ct -match 'xml' -or $body -match '<\?xml' -or $body -match '<rss' -or $body -match '<feed') { return 'xml' }
    if ($ct -match 'html' -or $body -match '<html' -or $body -match '<!DOCTYPE html') { return 'html' }
    return $null
}

# =====================================================
# Helpers
# =====================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine   = "[$timestamp] [$Level] $Message"

    # In Konsole ausgeben
    Write-Host $logLine

    # Optional in Datei schreiben
    $logFile = Join-Path $PSScriptRoot "script.log"
    Add-Content -Path $logFile -Value $logLine
}

function Convert-JsonCompat {
    <#
        .SYNOPSIS
        Wandelt JSON in Objekte um, funktioniert sowohl unter PS5.1 als auch unter PS7+.

        .PARAMETER Json
        Der JSON-String.

        .PARAMETER Depth
        (Optional) Maximale Tiefe der Konvertierung, wenn unterstuetzt.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Json,
        [int]$Depth = 5
    )

    $hasDepth = (Get-Command ConvertFrom-Json).Parameters.ContainsKey('Depth')

    if ($hasDepth) {
        return $Json | ConvertFrom-Json -Depth $Depth
    }
    else {
        return $Json | ConvertFrom-Json
    }
}

function Parse-IsoDate {
    param([string]$s)

    if ([string]::IsNullOrWhiteSpace($s)) { return $null }

    try {
        # ISO 8601 mit Zeitzonen
        return [DateTimeOffset]::Parse(
            $s,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
    }
    catch {
        # Fallback: erst versuchen, reines Datum yyyy-MM-dd zu parsen
        try {
            return [datetime]::ParseExact(
                $s.Trim(),
                'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
        catch {
            # Letzter Versuch: Standard-Cast
            try { return [datetime]$s } catch { return $null }
        }
    }
}

function Get-NodeText {
    param(
        [xml]$xml,
        [string]$xpath,
        [System.Xml.XmlNamespaceManager]$ns
    )

    $node = $xml.SelectSingleNode($xpath, $ns)
    return if ($node) { $node.InnerText } else { $null }
}

function Parse-Debian-Title {
    param([string]$title)

    # Beispiel: "DSA-5988-1 chromium - security update"
    $id = $null
    $package = $null

    if ($title -match '^(DSA-\d+-\d+)\s+(.+?)\s*-\s*') {
        $id = $Matches[1]
        $package = $Matches[2]
    }

    [pscustomobject]@{
        Id      = $id
        Package = $package
    }
}

function Escape-Html {
    param([string]$Text)

    if ($null -eq $Text) { return '' }

    $Text -replace '&', '&amp;' `
        -replace '<', '&lt;' `
        -replace '>', '&gt;' `
        -replace '"', '&quot;' `
        -replace "'", '&#39;'
}

function Get-DisplayTime {
    param([datetime]$Date)

    if ($null -eq $Date) { return '' }

    return $Date.ToString("dd.MM.yyyy HH:mm")
}

function Map-Source {
    param(
        [string]$SourceName,
        [object]$RawData
    )

    switch -Regex ($SourceName) {

        '^GitHub Advisory$' {
            $RawData | ForEach-Object {
                $desc = $_.description
                [pscustomobject]@{
                    Source  = 'GitHub Advisory'
                    Title   = $_.summary
                    Full    = $desc
                    Short   = if ($desc -and $desc.Length -gt 120) { $desc.Substring(0, 120) + '...' } else { $desc }
                    Link    = $_.html_url
                    Date    = if ($_.published_at) { Parse-IsoDate $_.published_at } else { $null }
                    CVE     = $_.cve_id
                    GHSA    = $_.ghsa_id
                    Vendor  = $null
                    Product = $null
                    DueDate = $null
                    Notes   = $null
                }
            }
            break
        }


        '^CISA KEV$' {
            $RawData | ForEach-Object {
                $desc = $_.shortDescription
                [pscustomobject]@{
                    Source  = 'CISA KEV'
                    Title   = $_.vulnerabilityName
                    Full    = $desc
                    Short   = if ($desc -and $desc.Length -gt 120) { $desc.Substring(0, 120) + '...' } else { $desc }
                    Link    = if ($_.notes) { ($_.notes -split ';')[0].Trim() } else { "https://www.cisa.gov/known-exploited-vulnerabilities-catalog" }
                    Date    = if ($_.dateAdded) { Parse-IsoDate $_.dateAdded } else { $null }
                    CVE     = $_.cveID
                    GHSA    = $null
                    Vendor  = $_.vendorProject
                    Product = $_.product
                    DueDate = if ($_.dueDate) { [datetime]$_.dueDate } else { $null }
                    Notes   = $_.notes
                }
            }
            break
        }


        '^Heise Security$' {
            if ($RawData -is [System.Collections.IEnumerable] -and -not ($RawData -is [string]) -and $RawData.Count -gt 0 -and $RawData[0].PSObject.Properties.Name -contains 'Title') {
                $RawData | ForEach-Object {
                    $desc = $_.Description
                    [pscustomobject]@{
                        Source  = 'Heise Security'
                        Title   = $_.Title
                        Full    = $desc
                        Short   = if ($desc -and $desc.Length -gt 120) { $desc.Substring(0, 120) + '...' } else { $desc }
                        Link    = $_.Link
                        Date    = $_.Date
                        CVE     = $null
                        GHSA    = $null
                        Vendor  = $null
                        Product = $null
                        DueDate = $null
                        Notes   = $null
                    }
                }
            }
            elseif ($RawData) {
                if ($RawData -isnot [xml]) { [xml]$xml = $RawData } else { $xml = $RawData }
                $nsmgr = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $nsmgr.AddNamespace("atom", "http://www.w3.org/2005/Atom")
                $entries = $xml.SelectNodes("//atom:entry", $nsmgr)

                $entries | ForEach-Object {
                    $desc = if ($_.summary.'#cdata-section') { $_.summary.'#cdata-section' } else { $_.summary }
                    [pscustomobject]@{
                        Source  = 'Heise Security'
                        Title   = if ($_.title.'#cdata-section') { $_.title.'#cdata-section' } else { $_.title }
                        Full    = $desc
                        Short   = if ($desc -and $desc.Length -gt 120) { $desc.Substring(0, 120) + '...' } else { $desc }
                        Link    = $_.link.href
                        Date    = if ($_.published) { Parse-IsoDate $_.published } elseif ($_.updated) { Parse-IsoDate $_.updated } else { $null }
                        CVE     = $null
                        GHSA    = $null
                        Vendor  = $null
                        Product = $null
                        DueDate = $null
                        Notes   = $null
                    }
                }
            }
            else {
                @()
            }
            break
        }

        default {
            # Generischer Fallback fuer alle anderen Quellen
            $RawData | Where-Object { $_ -ne $null } | ForEach-Object {
                $desc = $_.Description
                if (-not $desc -and $_.summary) { $desc = $_.summary }
                if (-not $desc -and $_.content) { $desc = $_.content }

                [pscustomobject]@{
                    Source = if ($_.Source) { $_.Source } else { $SourceName }
                    Title  = $_.Title
                    Link   = $_.Link
                    Date   = $_.Date
                    Short  = if ($desc -and $desc.Length -gt 120) { $desc.Substring(0, 120) + '...' } else { $desc }
                    Full   = $desc
                }
            }
        }
    }
}

# Debug: count items with a date
$srcItems | Where-Object { $_.Date -ne $null } | Measure-Object | ForEach-Object {
    Write-Host "Mit Datum: $($_.Count)" -ForegroundColor Green
}

# =====================================================
# Block 3: Fetch-Source
# =====================================================
function Fetch-Source {
    param($src)
    Write-Host "Hole $($src.Name)..." -ForegroundColor Cyan

    $res = $null
    $raw = $null

    try {
        $headers = @{}
        if ($src.Url -like "https://api.github.com/*") {
            $headers['User-Agent'] = 'SecurityFeedScript'
            $headers['Accept'] = 'application/vnd.github+json'
        }

        if ($src.Name -eq 'GitHub Advisory') {
            $raw = @()
            for ($page = 1; $page -le 3; $page++) {
                $url = "https://api.github.com/advisories?per_page=100&page=$page&sort=published&order=desc"
                Write-Host "  -> Seite $page abrufen..."
                $pageRes = Invoke-RestMethod -Uri $url -TimeoutSec 20 -Headers $headers
                if ($pageRes) { $raw += $pageRes }
            }
            return $raw  # ← Gib die Advisories als Objekt zurueck
        }
        else {
            $res = Invoke-WebRequest -Uri $src.Url -TimeoutSec 20 -Headers $headers
            $raw = $res.Content
        }
    }
    catch {
        Write-Warning "Fehler bei $($src.Name): $($_.Exception.Message)"
        return @()
    }

    # Diagnoseausgabe nur bei WebRequest
    $ShowDiag = $true  # oder $false zum Deaktivieren

    # Diagnoseausgabe nur bei WebRequest
    if ($ShowDiag -and $res -and $res.Content) {
        $ct = $res.Headers.'Content-Type'
        Write-Host "  > Content-Type: $ct" -ForegroundColor DarkGray

        $preview = ($res.Content.Substring(0, [Math]::Min(160, $res.Content.Length))) -replace '\r?\n', ' '
        Write-Host "  > Preview: $preview" -ForegroundColor DarkGray
    }


    # Format-Erkennung
    $fmt = $src.Type
    if (-not $fmt -or $fmt -eq 'autodetect') {
        if ($src.Url -match '\.json($|\?)' -or $raw -match '^\s*{') {
            $fmt = 'json'
        }
        elseif ($src.Url -match '\.rdf($|\?)' -or $raw -match '<rdf:RDF') {
            $fmt = 'rdf'
        }
        elseif ($raw -match '<feed xmlns="http://www.w3.org/2005/Atom"') {
            $fmt = 'atom'
        }
        elseif ($raw -match '<rss' -or $raw -match '<channel>') {
            $fmt = 'xml'
        }
        else {
            $fmt = 'unknown'
        }
    }
    Write-Host "  > Erkanntes Format: $fmt" -ForegroundColor Yellow

    $items = @()

    switch ($fmt) {
        'json' {
            try {
                $j = Convert-JsonCompat -Json $raw -Depth 10

                if ($j.PSObject.Properties.Name -contains 'vulnerabilities') {
                    Write-Host "  > CISA-KEV-Struktur erkannt" -ForegroundColor Magenta
                    $items = $j.vulnerabilities
                }
                elseif ($j -is [System.Collections.IEnumerable] -and $j.Count -gt 0 -and $j[0].PSObject.Properties.Name -contains 'ghsa_id') {
                    Write-Host "  > GitHub-Advisory-Array erkannt" -ForegroundColor Magenta
                    $items = $j
                }
                else {
                    Write-Host "  > Unbekannte JSON-Struktur - Rohobjekte verwendet" -ForegroundColor DarkYellow
                    $items = @($j)
                }

                return $items
            }
            catch {
                Write-Warning "JSON-Parse-Fehler bei $($src.Name): $($_.Exception.Message)"
                return @()
            }
        }

        'atom' {
            try {
                [xml]$xml = $raw
                # Namespace-Manager fuer Atom
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace('atom', 'http://www.w3.org/2005/Atom')

                # Alle <entry>-Nodes holen
                $nodes = $xml.SelectNodes('//atom:entry', $ns)

                $items = foreach ($n in $nodes) {
                    # Titel aus CDATA oder Text
                    $title = if ($n.title.'#cdata-section') {
                        $n.title.'#cdata-section'
                    }
                    elseif ($n.title.'#text') {
                        $n.title.'#text'
                    }
                    else {
                        $n.title.InnerText
                    }

                    # Beschreibung aus summary oder content
                    $desc = if ($n.summary.'#cdata-section') {
                        $n.summary.'#cdata-section'
                    }
                    elseif ($n.summary.'#text') {
                        $n.summary.'#text'
                    }
                    elseif ($n.content.'#cdata-section') {
                        $n.content.'#cdata-section'
                    }
                    elseif ($n.content.'#text') {
                        $n.content.'#text'
                    }
                    else {
                        $n.summary.InnerText
                    }

                    # Link-Attribut holen
                    $linkNode = $n.SelectSingleNode('atom:link[@href]', $ns)
                    $link = if ($linkNode) { $linkNode.href } else { $null }

                    # Datum aus updated oder published
                    $dateStr = if ($n.updated) { $n.updated } elseif ($n.published) { $n.published } else { $null }

                    [pscustomobject]@{
                        Source      = $src.Name
                        Title       = $title
                        Description = $desc
                        Link        = $link
                        Date        = Parse-IsoDate $dateStr
                        Raw         = $n
                    }
                }
            }
            catch {
                Write-Warning "Atom-Parse-Fehler bei $($src.Name): $($_.Exception.Message)"
                return @()
            }
        }

        'rdf' {
            try {
                [xml]$xml = $raw
                $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
                $ns.AddNamespace('rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#')
                $ns.AddNamespace('rss', 'http://purl.org/rss/1.0/')
                $ns.AddNamespace('dc', 'http://purl.org/dc/elements/1.1/')
                $nodes = $xml.SelectNodes('//rss:item', $ns)
                $items = foreach ($n in $nodes) {
                    [pscustomobject]@{
                        Source      = $src.Name
                        Title       = $n.SelectSingleNode('rss:title', $ns).InnerText
                        Description = $n.SelectSingleNode('rss:description', $ns).InnerText
                        Link        = $n.SelectSingleNode('rss:link', $ns).InnerText
                        Date        = Parse-IsoDate ($n.SelectSingleNode('dc:date', $ns).InnerText)
                        Raw         = $n
                    }
                }
            }
            catch {
                Write-Warning "RDF-Parse-Fehler bei $($src.Name): $($_.Exception.Message)"
                return @()
            }
        }

        'xml' {
            try {
                [xml]$xml = $raw
                $nodes = $xml.rss.channel.item
                $items = $nodes | ForEach-Object {
                    [pscustomobject]@{
                        Source      = $src.Name
                        Title       = $_.title
                        Description = $_.description
                        Link        = $_.link
                        Date        = Parse-IsoDate $_.pubDate
                        Raw         = $_
                    }
                }
            }
            catch {
                Write-Warning "XML-Parse-Fehler bei $($src.Name): $($_.Exception.Message)"
                return @()
            }
        }

        default {
            Write-Warning "$($src.Name): Kein unterstuetztes Format"
            return @()
        }
    } # Ende switch

    Write-Host "  > Items: $($items.Count)" -ForegroundColor DarkGray
    return $items
}

# =====================================================
# Block 4: Hauptablauf (mit Debug & Fix)
# =====================================================
$totalCount = 0
$allItems = @()

foreach ($src in $sources) {
    # 1. Rohdaten holen
    $rawItems = Fetch-Source $src

    # 2. Quelle-spezifisch mappen
    $srcItems = Map-Source -SourceName $src.Name -RawData $rawItems

    Write-Host "Quelle: $($src.Name)" -ForegroundColor Cyan
    Write-Host "Rohdaten: $($rawItems.Count)" -ForegroundColor Yellow
    Write-Host "Gemappte Items: $($srcItems.Count)" -ForegroundColor Magenta

    # Zusaetzliche Debug-Ausgabe fuer Inhalte (nur wenn aktiviert)
    if ($ShowItemDebug) {
        $DebugLimit = 1  # Anzahl der anzuzeigenden Items

        foreach ($i in $srcItems | Select-Object -First $DebugLimit) {
            Write-Host ("  TITLE: " + $i.Title)
            Write-Host ("  FULL : " + ($i.Full -replace '\r?\n', ' '))
            Write-Host ("  SHORT: " + ($i.Short -replace '\r?\n', ' '))
            Write-Host ""
        }

        if ($srcItems.Count -gt $DebugLimit) {
            Write-Host "  ... weitere $($srcItems.Count - $DebugLimit) Eintraege unterdrueckt ..." -ForegroundColor DarkGray
        }
    }

    # Statistik mit/ohne Datum (immer anzeigen)
    $withDate = $srcItems | Where-Object { $_.Date -ne $null }
    $withoutDate = $srcItems | Where-Object { $_.Date -eq $null }
    Write-Host "$($src.Name): Mit Datum: $($withDate.Count) / Ohne Datum: $($withoutDate.Count)" -ForegroundColor Gray

    # 3. Sicherstellen, dass jedes Objekt die Properties hat (nur ergaenzen, nicht ueberschreiben)
    $srcItems = $srcItems | ForEach-Object {
        if (-not ($_.PSObject.Properties.Name -contains 'Date')) {
            $_ | Add-Member -NotePropertyName Date -NotePropertyValue $null
        }
        if (-not ($_.PSObject.Properties.Name -contains 'Full')) {
            $_ | Add-Member -NotePropertyName Full -NotePropertyValue ""
        }
        if (-not ($_.PSObject.Properties.Name -contains 'Short')) {
            $_ | Add-Member -NotePropertyName Short -NotePropertyValue ""
        }
        $_
    }

    # 4. Sammeln & zaehlen
    $allItems += $srcItems
    $count = $srcItems.Count
    $totalCount += $count
    Write-Host "$($src.Name): $count Eintraege gefunden" -ForegroundColor Green
}

# Optional: Gesamtstatistik am Ende
Write-Host ""
Write-Host "=== Gesamtstatistik ===" -ForegroundColor Blue
Write-Host "Total: $totalCount Eintraege" -ForegroundColor White

# ============================================================
# NEUER FILTERBEREICH (mit Bypass fuer bestimmte Quellen)
# ============================================================

# 0 = kein Zeitfilter; >0 = Anzahl Stunden, z. B. 48 fuer die letzten 2 Tage
$Filter_TimeWindowHours = 48
# Leerlassen = kein Stichwortfilter; sonst z. B. @('Windows','Office 365','Exchange')
$Filter_IncludeKeywords = @(
    'microsoft', 'windows', 'office365', 'office',
    'apache tomcat', 'apache HTTP', 'vmware', 'linux',
    'google chrome', 'firefox', 'apple', 'whatsapp', 'twitter', 'instagram',
    'PDF', 'exchange', 'outlook', 'edge', 'teams', 'sharepoint',
    'sql server', 'IIS', 'azure', 'active directory'
)
$Filter_ExcludeSources = @('Heise Security', 'BSI BuergerCERT')  # Immer durchlassen

# === Filter-Logik vorbereiten ===
$noTimeFilter = ($Filter_TimeWindowHours -le 0)
if (-not $noTimeFilter) {
    $cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-$Filter_TimeWindowHours)
}

$regex = $null
if ($Filter_IncludeKeywords.Count -gt 0) {
    $pattern = ($Filter_IncludeKeywords | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Bypass-Muster (Teiltreffer erlaubt, case-insensitive)
$bypassPattern = $null
if ($Filter_ExcludeSources.Count -gt 0) {
    $bypassPattern = ($Filter_ExcludeSources | ForEach-Object { [regex]::Escape($_) }) -join '|'
}

# === 1. Bypass-Quellen separat sammeln ===
$bypassItems = $allItems | Where-Object {
    $src = ([string]$_.Source).Trim()
    $bypassPattern -and ($src -match $bypassPattern)
}

# === 2. Normale Filterung auf alle anderen Quellen anwenden ===
$filteredItems = $allItems | Where-Object {
    $src = ([string]$_.Source).Trim()

    # Nur weiter pruefen, wenn Quelle NICHT in der Bypass-Liste ist
    if ($bypassPattern -and ($src -match $bypassPattern)) { return $false }

    $keep = $true

    # Zeitfilter
    if (-not $noTimeFilter -and $_.Date -is [datetime]) {
        if ($_.Date -lt $cutoffUtc) {
            Write-Host "Verworfen (Zeit): $($src) - $([string]$_.Title)" -ForegroundColor DarkYellow
            $keep = $false
        }
    }

    # Keywordfilter (Strings null-sicher casten)
    if ($regex -and $keep) {
        $title = [string]$_.Title
        $desc = [string]$_.Description
        $full = [string]$_.Full
        if (-not ($regex.IsMatch($title) -or $regex.IsMatch($desc) -or $regex.IsMatch($full))) {
            Write-Host "Verworfen (Kein Keyword): $($src) - $([string]$_.Title)" -ForegroundColor DarkRed
            $keep = $false
        }
    }

    return $keep
}

# === 3. Ergebnisse zusammenfuehren ===
$feedsFiltered = @($bypassItems + $filteredItems)

# === Debug-Ausgabe (statisch, immer anzeigen) ===
Write-Host ""
Write-Host "=== Filterergebnis ===" -ForegroundColor Cyan
Write-Host ("  Gesamt vor Filter        : {0}" -f $allItems.Count)        -ForegroundColor Yellow
Write-Host ("  Bypass-Quellen           : {0}" -f $bypassItems.Count)      -ForegroundColor Magenta
Write-Host ("  Gefilterte Eintraege      : {0}" -f $filteredItems.Count)    -ForegroundColor Green
Write-Host ("  Gesamt nach Zusammenfuehrung: {0}" -f $feedsFiltered.Count)  -ForegroundColor Cyan
Write-Host ""

# ============================================================
# NORMALISIERUNG & STATISTIK (Erweiterter Test) - PS 5.1
# ============================================================

# Debug-Schalter fuer Beispielausgabe
$ExampleLimit = 2       # Anzahl der Items in der Beispielausgabe

function Clean-Text($text) {
    if (-not $text) { return '' }

    # Erst Umlaute ersetzen
    $text = $text -replace 'ä', 'ae' -replace 'Ä', 'Ae'
    $text = $text -replace 'ö', 'oe' -replace 'Ö', 'Oe'
    $text = $text -replace 'ü', 'ue' -replace 'Ü', 'Ue'
    $text = $text -replace 'ß', 'ss'

    # Problematische Zeichen entfernen, aber HTML-Tags (< >) durchlassen
    return ($text -replace '[^\w .,;:!?_\-\/<>]', '')
}

function Highlight-Keywords($text) {
    if (-not $text) { return '' }

    $keywords = @('hoch', 'high', 'kritisch', 'urgent')
    foreach ($word in $keywords) {
        $pattern = "(?i)\b$word\b"
        $text = $text -replace $pattern, "<span class='highlight'>$word</span>"
    }
    return $text
}

Write-Host ""
Write-Host "Vor Normalisierung: $($feedsFiltered.Count) Items" -ForegroundColor Yellow

# Minimal-Normalisierung: nur Nulls raus
$feeds = $feedsFiltered | Where-Object { $_ -ne $null }

# Felder absichern und Normalisierung anwenden
$feeds = $feeds | ForEach-Object {
    # Fehlende Properties ergaenzen
    if (-not ($_.PSObject.Properties.Name -contains 'Title'))       { $_ | Add-Member -NotePropertyName Title       -NotePropertyValue '' }
    if (-not ($_.PSObject.Properties.Name -contains 'Description')) { $_ | Add-Member -NotePropertyName Description -NotePropertyValue '' }
    if (-not ($_.PSObject.Properties.Name -contains 'Full'))        { $_ | Add-Member -NotePropertyName Full        -NotePropertyValue '' }
    if (-not ($_.PSObject.Properties.Name -contains 'Link'))        { $_ | Add-Member -NotePropertyName Link        -NotePropertyValue '' }

    # Original-Link sichern (unverändert lassen)
    $linkRaw = $_.Link

    # Erst bereinigen (nur Textfelder)
    $titleClean = Clean-Text([string]$_.Title)
    $descClean  = Clean-Text([string]$_.Description)
    $fullClean  = Clean-Text([string]$_.Full)

    # Dann highlighten
    $_.Title       = Highlight-Keywords($titleClean)
    $_.Description = Highlight-Keywords($descClean)
    $_.Full        = Highlight-Keywords($fullClean)

    # Link wieder einsetzen (unverändert)
    $_.Link = $linkRaw

    $_
}

Write-Host "Nach Minimal-Normalisierung: $($feeds.Count) Items" -ForegroundColor Yellow

# Statistik: leere Felder zaehlen
$emptyTitleCount = ($feeds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Title) }).Count
$emptyDescCount  = ($feeds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Description) }).Count
$emptyFullCount  = ($feeds | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Full) }).Count

Write-Host "Leere Titel: $emptyTitleCount"       -ForegroundColor DarkYellow
Write-Host "Leere Description: $emptyDescCount" -ForegroundColor DarkYellow
Write-Host "Leere Full: $emptyFullCount"        -ForegroundColor DarkYellow

# Bonus: Anzahl markierter Keywords zaehlen
$highlightCount = ($feeds | Where-Object {
        $_.Title       -match '<span class=.highlight.>' -or
        $_.Description -match '<span class=.highlight.>' -or
        $_.Full        -match '<span class=.highlight.>'
    }).Count
Write-Host "Eintraege mit Keyword-Highlight: $highlightCount" -ForegroundColor Cyan

# Beispielausgabe (nur wenn aktiviert)
if ($ShowExampleItems) {
    Write-Host ""
    Write-Host "=== Beispielausgabe der ersten $ExampleLimit Items ===" -ForegroundColor Cyan
    $feeds | Select-Object Source, Title, Description, Full, Link -First $ExampleLimit | Format-List
    if ($feeds.Count -gt $ExampleLimit) {
        Write-Host "  ... weitere $($feeds.Count - $ExampleLimit) Eintraege unterdrueckt ..." -ForegroundColor DarkGray
    }
}

# ============================================================
# HTML-Export: Gruppiert nach Quelle mit Sprungnavigation
# ============================================================

# Pfad fuer HTML-Datei
$HtmlFilePath = Join-Path $PSScriptRoot 'feeds.html'

# Gruppieren nach Quelle
$groups = $feeds | Group-Object Source | Sort-Object Name

# HTML-Header mit CSS & JS
$html = @"
<!DOCTYPE html>
<html lang="de">
<head>
  <meta charset="UTF-8">
  <title>Feed-Ueersicht</title>
  <style>
    body {
      font-family: "Segoe UI", Arial, sans-serif;
      font-size: 14px;
      color: #222;
      margin: 20px;
    }
    table {
      border-collapse: collapse;
      width: 100%;
      table-layout: fixed;
      /* table-layout: auto;  erlaubt flexible Spaltenbreite */
      margin-bottom: 20px;
    }
    th, td {
      border-bottom: 1px solid #ddd;
      padding: 6px 8px;
      vertical-align: middle;
    }
    th {
      background-color: #f3f2f1;
      text-align: left;
      white-space: nowrap;
    }
    colgroup col:nth-child(1) { width: 140px; }
    colgroup col:nth-child(2) { width: 130px; }
    colgroup col:nth-child(3) { width: 850px; }

    .feed-title a {
      font-weight: bold;
      color: black;
      text-decoration: none;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      display: inline-block;
      max-width: 100%;
    }
    .feed-title.open a {
      white-space: normal;
      overflow: visible;
      text-overflow: unset;
      max-width: none;
    }
    .feed-desc-wrapper {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .feed-desc-text {
      flex: 1;
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      margin-right: 8px;
    }
    .feed-desc-full {
      display: none;
      white-space: normal;
      overflow: visible;
      margin-right: 8px;
    }
    .feed-desc-wrapper.open .feed-desc-full {
      display: inline;
    }
    .feed-desc-wrapper.open .feed-desc-text {
      display: none;
    }
    .more-btn {
      flex-shrink: 0;
      padding: 4px 8px;
      background-color: #0078d4;
      color: white;
      border: none;
      border-radius: 4px;
      cursor: pointer;
    }
    .more-btn:hover {
      background-color: #005a9e;
    }
    nav ul {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      padding: 0;
      list-style: none;
      margin-bottom: 20px;
    }
    nav li a {
      text-decoration: none;
      background-color: #f3f2f1;
      padding: 6px 12px;
      border-radius: 4px;
      display: inline-block;
      transition: background-color 0.3s;
    }
    nav li a:hover {
      background-color: #e1dfdd;
    }
    h2 {
      margin-top: 40px;
    }
    .top-link {
      margin-top: 10px;
      display: inline-block;
      font-size: 13px;
      color: #0078d4;
      text-decoration: none;
    }
    .top-link:hover {
      text-decoration: underline;
    }
    .group-heading {
    font-size: 1.2em;               /* kleinere Schriftgroesse */
    background-color: #0078D4;      /* Microsoft-Blau */
    color: white;                   /* weiße Schrift */
    padding: 6px 12px;              /* etwas Innenabstand */
    border-radius: 4px;             /* leicht abgerundete Ecken */
    margin-top: 30px;               /* Abstand zur vorherigen Tabelle */
    }
    .highlight {
    background-color: #fff2cc; /* sanftes Gelb */
    color: #d83b01;            /* Microsoft-Rot */
    font-weight: bold;
    padding: 0 2px;
    border-radius: 2px;
    }
    </style>
  <script>
    function toggleRow(id) {
      const wrapper   = document.getElementById('wrapper-' + id);
      const a         = document.getElementById('title-'   + id);
      const btn       = document.getElementById('btn-'     + id);
      const open = wrapper.classList.toggle('open');
      const titleCell = a?.closest('.feed-title');
      if (titleCell) titleCell.classList.toggle('open', open);
      if (btn) btn.textContent = open ? 'Weniger...' : 'Mehr...';
    }
  </script>
</head>
<body>
<a id="top"></a>
<h3> </h3>
<nav><ul>
"@

# Inhaltsverzeichnis
foreach ($group in $groups) {
    $anchor = ($group.Name -replace '\s', '_') -replace '[^A-Za-z0-9_]', ''
    $html += "<li><a href='#$anchor'>$($group.Name)</a> ($($group.Count))</li>"
}
$html += "</ul></nav>"

# Hilfsfunktionen
Add-Type -AssemblyName System.Web

function Html-AttrEncode([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return [System.Web.HttpUtility]::HtmlAttributeEncode($s)
}

function Fix-LinkIfBroken([string]$link) {
    if ([string]::IsNullOrWhiteSpace($link)) { return $link }

    # uuid-Pattern ohne '=' → ?uuid<GUID> → ?uuid=<GUID>
    if ($link -match '(?i)(\?|\&)(uuid)([0-9a-f\-]{36})$') {
        return ($link -replace '(?i)(\?|\&)(uuid)([0-9a-f\-]{36})$', '$1$2=$3')
    }

    # name-Pattern ohne '=' → ?nameWID-SEC-... → ?name=WID-SEC-...
    if ($link -match '(?i)(\?|\&)(name)([A-Za-z0-9_\-\.]+)$') {
        return ($link -replace '(?i)(\?|\&)(name)([A-Za-z0-9_\-\.]+)$', '$1$2=$3')
    }

    return $link
}

# Tabellen pro Gruppe
foreach ($group in $groups) {
    $anchor = ($group.Name -replace '\s', '_') -replace '[^A-Za-z0-9_]', ''
    $html += "<h3 id='$anchor' class='group-heading'>$($group.Name)</h3>"
    $html += "<table class='feed-table'>"
    $html += @"
<table>
  <colgroup>
    <col><col><col><col>
  </colgroup>
  <thead>
    <tr>
      <th>Datum</th>
      <th>Quelle</th>
      <th>Titel</th>
      <th>Beschreibung</th>
    </tr>
  </thead>
  <tbody>
"@

    foreach ($item in $group.Group) {
        $dateStr = if ($item.Date) {
            try { ([datetime]$item.Date).ToString('yyyy-MM-dd HH:mm') } catch { $item.Date }
        } else { '-' }

        $src = Clean-Text $item.Source

        # Link unveraendert aus den Daten nehmen, ggf. reparieren und HTML-sicher encoden
        $linkRaw   = $item.Link
        $linkFixed = Fix-LinkIfBroken($linkRaw)
        $link      = if ($linkFixed) { Html-AttrEncode $linkFixed } else { '#' }

        $id = [guid]::NewGuid().ToString('N')

        # Erst bereinigen, dann highlighten (nur Textfelder)
        $title = Highlight-Keywords (Clean-Text $item.Title)
        $short = Highlight-Keywords (Clean-Text $item.Short)
        $full  = Highlight-Keywords (Clean-Text $item.Full)

        $html += @"
<tr>
  <td>$dateStr</td>
  <td>$src</td>
  <td class="feed-title">
    <a href="$link" target="_blank" id="title-$id">$title</a>
  </td>
  <td class="feed-desc-wrapper" id="wrapper-$id">
    <span class="feed-desc-text" id="short-$id">$short</span>
    <span class="feed-desc-full" id="full-$id">$full</span>
    <button class="more-btn" id="btn-$id" onclick="toggleRow('$id')">Mehr...</button>
  </td>
</tr>
"@
    }

    $html += "</tbody></table>"
    $html += "<p><a class='top-link' href='#top'>Zurueck nach oben</a></p>"
}

# HTML-Ende
$html += "</html>"


#===========================
# Block: HTML-Erstellung & Aufraeumen
#===========================
$resultDir = Join-Path $PSScriptRoot "result"
if (-not (Test-Path $resultDir)) {
    New-Item -Path $resultDir -ItemType Directory | Out-Null
}

# Dateiname mit Zeitstempel
$timestamp   = Get-Date -Format "yyyy-MM-dd_HH-mm"
$FileName    = "security_feed_{0}.html" -f $timestamp
$HtmlFilePath = Join-Path $resultDir $FileName

# HTML schreiben
$html -join "`r`n" | Out-File -FilePath $HtmlFilePath -Encoding UTF8
Write-Host "HTML-Datei erstellt: $HtmlFilePath" -ForegroundColor Green

# Aufräum-Parameter
$zipAfterDays   = 90
$deleteZipAfter = 180

# HTMLs älter als $zipAfterDays zippen
$oldHtmlFiles = Get-ChildItem -Path $resultDir -Recurse -Filter *.html |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$zipAfterDays) }

if ($oldHtmlFiles) {
    $zipName = "archiv_{0}.zip" -f (Get-Date -Format "yyyy-MM-dd_HH-mm")
    $zipPath = Join-Path $resultDir $zipName
    Compress-Archive -Path $oldHtmlFiles.FullName -DestinationPath $zipPath -Force
    Write-Host "Archiv erstellt: $zipPath" -ForegroundColor Yellow
    $oldHtmlFiles | Remove-Item -Force
}

# ZIPs älter als $deleteZipAfter löschen
$oldZips = Get-ChildItem -Path $resultDir -Recurse -Filter *.zip |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$deleteZipAfter) }

if ($oldZips) {
    $oldZips | Remove-Item -Force
    Write-Host ("{0} alte ZIP-Dateien geloescht." -f $oldZips.Count) -ForegroundColor DarkGray
}

# ===========================
# Block: E-Mail Versand
# ===========================

# Standardwert fuer SendEmail
$SendEmail = $true

# SMTP Konfiguration laden
$configFile = Join-Path $PSScriptRoot "smtpConfig.psd1"
if (-not (Test-Path $configFile)) {
    throw "SMTP config file not found: $configFile"
}
$smtpConfig = Import-PowerShellDataFile -Path $configFile

$SmtpServer = $smtpConfig.SmtpServer
$SmtpPort   = $smtpConfig.SmtpPort
$From       = $smtpConfig.From
$To         = $smtpConfig.To
$Subject    = $smtpConfig.Subject

# UNC-Link dynamisch aus Dateiname
$HtmlLink = "\\ttbvmdc02\cve_result\$FileName"

# Inhaltsverzeichnis vorbereiten (Beispielwerte – hier deine echten Variablen einsetzen)
$TOC = @(
    "BSI BuergerCERT (100)",
    "BSI CERT-SEC (71)",
    "GitHub Advisory (12)",
    "Heise Security (20)"
)

# Pruefen, ob Inhalt identisch zur letzten HTML-Datei ist
$lastFile = Get-ChildItem $resultDir -Filter "security_feed_*.html" |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 1 -First 1
$IsDuplicate = $false
if ($lastFile) {
    $newHash  = Get-FileHash -Path $HtmlFilePath -Algorithm SHA256
    $oldHash  = Get-FileHash -Path $lastFile.FullName -Algorithm SHA256
    $IsDuplicate = ($newHash.Hash -eq $oldHash.Hash)
}

# Klartext-Body mit einfachem "Design"
$BodyText  = "New CVE report generated.`n"
$BodyText += "You can view the full report here:`n$HtmlLink`n`n"
$BodyText += "=== Overview ===`n"
$BodyText += ($TOC -join "`n")
$BodyText += "`n================`n"

# Debug-Ausgaben
Write-Host "=== DEBUG START ===" -ForegroundColor Yellow
Write-Host "SendEmail:    $SendEmail" -ForegroundColor Yellow
Write-Host "IsDuplicate:  $IsDuplicate" -ForegroundColor Yellow
Write-Host "LastFile:     $($lastFile.FullName)" -ForegroundColor Yellow
Write-Host "=== DEBUG END ===" -ForegroundColor Yellow

# Versandlogik
if ($SendEmail -and -not $IsDuplicate) {
    Send-MailMessage -From $From -To $To -Subject $Subject -Body $BodyText `
        -SmtpServer $SmtpServer -Port $SmtpPort -BodyAsHtml:$false
    Write-Host "E-Mail successfully sent." -ForegroundColor Green
}
else {
    Write-Host "E-Mail sending skipped." -ForegroundColor Red
    if (-not $SendEmail) { Write-Host "Reason: SendEmail = $SendEmail" -ForegroundColor Red }
    if ($IsDuplicate)    { Write-Host "Reason: Content identical to last version" -ForegroundColor Red }
}

# ===========================
# ENDE: Stand speichern (nur bei Aenderung)
# ===========================
$projectState = [PSCustomObject]@{
    Timestamp            = (Get-Date).ToString("s")
    FeedCountTotal       = $feeds.Count
    FeedCountAfterCutoff = $feedsAfterCutoff.Count
    FeedCountFiltered    = $feedsFiltered.Count
    Cutoff               = $cutoffStr
    Keywords             = $keywords
}

$shouldWrite = $true
if (Test-Path $stateFile) {
    $lastStateJson = Get-Content $stateFile -Raw
    $currentStateJson = ($projectState | ConvertTo-Json -Depth 3)
    if ($lastStateJson -eq $currentStateJson) {
        $shouldWrite = $false
    }
}

if ($shouldWrite) {
    $projectState | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8
    Write-Host "Projektstatus aktualisiert." -ForegroundColor Green
}
else {
    Write-Host "Projektstatus unverändert - kein Schreibvorgang." -ForegroundColor DarkGray
}

$ShowDebug = $true   # oder $false
$rawItems = $allItems | Where-Object { $_.Source -like $src.Name }