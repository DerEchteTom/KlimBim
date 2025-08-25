---------------------------------------------------------------
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
---------------------------------------------------------------


📦 README.md – Installations-Snapshot & Reporting-System


# 🧰 Installations-Snapshot & Reporting-System

Ein PowerShell-basiertes Tool zur Erfassung, Speicherung und Visualisierung installierter Anwendungen auf einem Windows-System.  
Ideal für Systemanalysen, Change-Tracking und Software-Inventarisierung.

---

## 📁 Projektstruktur

InMon/  ├── installations.db         		# SQLite-Datenbank 
        ├── InitDatabase.ps1         		# Erstellt die Datenbankstruktur 
        ├── SnapshotManager.ps1      		# Erfasst installierte Anwendungen 
        ├── Generate.ps1             		# Erstellt HTML-Bericht 
        ├── GenerateDiff.ps1           		# Erstellt HTML-Bericht 
        ├── Helper.ps1               		# SQLite-Schnittstelle via Invoke-SqliteCli 
        ├── send.ps1               		# Versendet Reports per E-Mail 
	└── Report		     		# Generierter Bericht Verzeichnis
               └── report_YYYYMMDD_HHMM.html 	# Generierter Bericht

---

## ⚙️ Komponenten und Funktionen

### InitDatabase.ps1

Initialisiert die Datenbank installations.db.
- Funktion: (Hauptlogik ohne separate Funktionen)
- Aufgabe: Erzeugt Tabellen Snapshots und SnapshotApps, legt Indizes an.
- Ergebnis: Leere, einsatzbereite Datenbankstruktur.

### SnapshotManager.ps1

Erstellt einen neuen Snapshot des aktuellen Systemzustands und speichert installierte Anwendungen.
- Get-StableKey(name, version, publisher)
- Aufgabe: Bildet einen stabilen, normalisierten Schlüssel je App aus Name, Version, Publisher; Hash via SHA-256.
- Input: Name, Version, Publisher (Strings; Null/Leer wird zu "" normalisiert).
- Output: Hex-String (ohne Bindestriche).
- Hinweis: Kulturunabhängige Kleinschreibung und Trim sorgen für deterministische Schlüssel.
- Convert-InstallDate(rawDate)
- Aufgabe: Konvertiert Registry-Format yyyyMMdd in yyyy-MM-dd.
- Input: Rohdatum (String).
- Output: Formatierter String oder $null.
- Get-InstalledApps()
- Aufgabe: Liest installierte Anwendungen aus Registry-Zweigen (HKLM, WOW6432, HKCU) aus.
- Output: Liste von PSCustomObjects mit Feldern:
- UniqueKey, DisplayName, Version, Publisher, Source, InstallDate, StableKey.
- Hinweis: Version fällt bei fehlendem Wert auf "unknown" zurück.
- Show-AllSnapshots()
- Aufgabe: Listet alle Snapshots (ID, Zeitpunkt, Typ) in der CLI auf.
- Output: Konsolenausgabe.
- Hauptlogik
- Deduplication: Sortiert und gruppiert nach StableKey; pro Key wird ein Eintrag übernommen.
- ScanHash: SHA-256 über sortierte StableKeys; dient zum Erkennen unveränderter Zustände.
- Skip-Logik: Wenn letzter ScanHash identisch ist, wird kein neuer Snapshot erstellt.
- Diff-Check (SQL): Prüft bei Bedarf NEW/REMOVED/UPDATED zwischen letztem Snapshot und aktuellem Zustand.
- Persistenz: Speichert Snapshot (Snapshots) und Apps (SnapshotApps).
- Ausgabe: Konsolen-Infos und Zusammenfassung.
- Optionale Debug-Ausgaben
- $DebugOutput/$DebugMode: Zusätzliche CLI-Logs (z. B. Unterschiede zum letzten Snapshot, gefilterte Einträge)

### GenerateReport.ps1

Erstellt einen vollständigen, globalen HTML‑Report mit allen in der Datenbank erfassten Snapshots und zugehörigen Anwendungen.
- Zweck:
- Liefert eine Gesamtübersicht aller Snapshots, installierten Apps, historischer Erstsichtungen und des App‑Trends – ohne Einschränkung auf Diffs oder Teilmengen.
- Ideal für Gesamtinventuren oder Langzeitauswertungen.
- Hauptfunktionen:
- Verzeichnisprüfung: Erstellt bei Bedarf automatisch den Ordner .\report.
- Zeitstempel & Dateiname: Baut den Ausgabepfad .\report\report_YYYYMMDD_HHMM.html.
- HTML‑Grundgerüst: Setzt ein einheitliches Layout inkl. CSS‑Styles für Tabellen, Überschriften und Abschnitte.
- Add‑TableSection($Title,$Sql,$Headers):
- Führt über Invoke‑SqliteCli SQL‑Abfragen gegen $Global:InstallDbPath aus.
- Wandelt die Resultate in HTML‑Tabellen um (inkl. Überschrift und Spaltennamen).
- Bei leeren Resultaten Ausgabe eines „No data available“-Hinweises.
- SQL‑Abfragen:
- Snapshot Overview: Alle Snapshots mit ID, Zeitstempel, Notiz, AppCount, gekürztem ScanHash.
- Installed Applications per Snapshot: Vollständige App‑Listen pro Snapshot.
- Installation Timeline: Erstsichtungsdatum jeder Anwendung.
- App Count Trend: Zeitlicher Verlauf der Gesamtanzahl installierter Apps.
- Sektionen hinzufügen: Fügt die vier Tabellenabschnitte nacheinander ins HTML ein.
- HTML‑Abschluss & Speichern: Schreibt das finale HTML‑Dokument (UTF‑8) in $outputFile.
- CLI‑Feedback: Meldet den Speicherort des erstellten Reports.
 - Besonderheiten:
 - Einheitliche HTML‑Darstellung auch bei großen Datenmengen.
 - Unabhängig vom Diff‑Report (GenerateDiff.ps1) – kann parallel genutzt werden

### GenerateDiff.ps1

Erzeugt einen HTML-Bericht aus den gespeicherten Daten.
- IsExcludedPublisher(publisher)
- Aufgabe: Prüft, ob der Herausgeber anhand einer Ausschlussliste gefiltert werden soll.
- Input: Publisher (String).
- Output: $true/$false.
- Hinweis: Case-insensitive Teilstring-Match; Liste konfigurierbar via $excludedPublishers.
- Show-AllSnapshots()
- Aufgabe: Zeigt verfügbare Snapshots in der CLI an (Hilfsfunktion für Auswahl).
- Select-ByDate() / Select-ByID() / Select-LastN()
- Aufgabe: Interaktive Auswahl von Snapshots (Zeitfenster, ID-Bereich, letzte N).
- Output: Liste ausgewählter SnapshotIDs (Strings).
- Berichtserstellung
- Header/Styles: Erstellt ansprechenden HTML-Kopf mit Metadaten (Typ, Zeitpunkt, Filterinfo).
- Zeilen-Append: Schreibt pro App eine Tabellenzeile (SnapshotID, DisplayName, Version, Publisher, Source, InstallDate).
- Footer: Schließt die Tabelle und das Dokument ab.
- Pfad & Ordner: Legt report\report_YYYYMMDD_HHMM_diff.html an; erstellt den Ordner bei Bedarf automatisch.
- Filter
- Publisher-Filter: Ausschluss bekannter Vendoren (z. B. microsoft, adobe, oracle, nvidia).
- InstallDate-Filter (optional): Ausgabe aller Apps, die in einem Zeitbereich installiert wurden.

### Helper.ps1

Stellt die SQLite-CLI-Integration und globale Pfade bereit.
- Invoke-SqliteCli -DbFile <path> -Sql <query> -Silent
- Aufgabe: Führt SQL gegen installations.db aus.
- Input: Pfad zur DB, SQL-Text, optional Silent-Modus.
- Output: Zeilenweise Ausgabe als Strings (Pipe-fähig).
- Hinweis: Nutzt $Global:SqliteExe (Pfad zur sqlite3.exe) und $Global:InstallDbPath (Pfad zur DB).


---

## 🧱 Datenbankstruktur

Tabelle: Snapshots
| Spalte 	| Typ 		| Beschreibung 				| 
| SnapshotID 	| INTEGER 	| Primärschlüssel 			| 
| CreatedAt 	| TEXT 		| Zeitstempel des Snapshots		| 
| Note 		| TEXT 		| Freitextnotiz 			| 
| AppCount 	| INTEGER 	| Anzahl erkannter Apps 		| 
| ScanHash 	| TEXT 		| Hashwert des Gesamtzustands 		| 
| IsInitial 	| INTEGER 	| 1 = Initialer Snapshot, 0 = Inkrement | 


Tabelle: SnapshotApps
| Spalte 	| Typ 		| Beschreibung 				| 
| SnapshotID 	| INTEGER 	| Verknüpfung zu Snapshots 		| 
| StableKey 	| TEXT		| Stabiler Schlüssel (Name+Version+Pub) | 
| UniqueKey 	| TEXT 		| Rohschlüssel aus Quelle (z. B. GUID) 	| 
| DisplayName 	| TEXT 		| Name der Anwendung 			| 
| Version 	| TEXT 		| Versionsnummer 			| 
| Publisher 	| TEXT 		| Herausgeber 				| 
| Source 	| TEXT 		| Quelle (HKLM/WOW6432/HKCU) 		| 
| InstallDate 	| TEXT 		| Installationsdatum (yyyy-MM-dd) 	| 

---

## 🚀 Nutzung

### 1. Datenbank initialisieren

PowerShell  .\InitDatabase.ps1

### 2. Snapshot erstellen

PowerShell  .\SnapshotManager.ps1

### 3. Bericht generieren
PowerShell  .\Generate.ps1
PowerShell  .\GenerateDiff.ps1

### 4. Bericht anzeigen
PowerShell  Start-Process .\report_YYYYMMDD_HHMM.html

---

## 🔧Konfiguration und Einstellungen
- DB-Pfad:
- Variable: $Global:InstallDbPath
- Beschreibung: Vollständiger Pfad zur installations.db.
- SQLite-CLI:
- Variable: $Global:SqliteExe
- Beschreibung: Pfad zur sqlite3.exe.
- Publisher-Filter (generate.ps1):
- Variable: $excludedPublishers = @("microsoft","adobe","oracle","nvidia")
- Beschreibung: Case-insensitive Ausschlussliste.
- Debug-Ausgaben:
- Variable: $DebugOutput / $DebugMode
- Beschreibung: Aktiviert zusätzliche CLI-Logs (z. B. Diff-Ausgaben, Filtertreffer).
- Report-Pfad:
- Variable: htmlPath = ".\report\report_{timestamp}_diff.html"
- Hinweis: Ordner wird vor dem Schreiben erzeugt.

---

## 🛠️ Debugging und Diff-Checks
- Deterministik:
- Maßnahme: Vor Dedup sortieren nach StableKey, UniqueKey; pro StableKey ersten Eintrag nehmen.
- Ziel: Stabiler ScanHash, keine „Geister“-Snapshots durch wechselnde Reihenfolge.
- Vergleich alt/neu:
- CLI-Diff: Compare-Object zwischen (StableKey, Version) des letzten Snapshots und aktuellem Scan.
- Ausgabe: NEW / REMOVED / CHANGED; bei Gleichheit „0 differences – lists are identical“.
- Skip-Bedingung:
- Logik: Gleichheit von ScanHash ⇒ Snapshot wird übersprungen; sonst Incremental-Snapshot.

---

## ✉️ E-Mail-Versand (send.ps1)
- Aufgabe: Versendet eine E-Mail mit Informationen (z. B. Snapshot-Zusammenfassung) und optional dem aktuellen HTML-Report als Anhang.
- Typische Parameter/Variablen:
- SMTP: Server, Port, Auth (Benutzer/Kennwort).
- E-Mail: From, To, Subject, Body (Text/HTML).
- Anhänge: Pfad zum generierten Report (z. B. .\report\report_YYYYMMDD_HHMM_diff.html).
- Aufrufbeispiel:
.\send.ps1 -To "it@example.com" -Subject "Daily snapshot report" -Attach ".\report\report_YYYYMMDD_HHMM_diff.html"

---

## 🧪 Beispielbericht

Der HTML-Bericht enthält:
- Übersicht aller Snapshots
- Liste aller installierten Apps pro Snapshot
- Zeitliche Erst-Sichtung jeder App
- Trend der App-Zahl über die Zeit
