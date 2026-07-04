# STEMwerk Windows-Setup-Anleitung

Diese Anleitung gilt fuer den Windows-Installer von STEMwerk 2.3.0.0.

## Was der Installer gerade gemacht hat

Der Windows-Installer hat:

- die STEMwerk REAPER-Skripte installiert
- die STEMwerk-Runtime unter `%LOCALAPPDATA%\STEMwerk` vorbereitet
- die von STEMwerk verwendete Python-Umgebung erstellt oder aktualisiert
- FFmpeg und die zentralen Runtime-Pakete geprueft
- gebuendelte Drum-Kit-Runtime- und Offline-Modell-Payloads installiert, wenn sie in diesem Installer enthalten sind

Der Windows-Installer bleibt der empfohlene Weg fuer Erstinstallation und Reparatur unter Windows.

## Installer-Typen

- `Online-Installer`: kleinerer Installer; er kann bei Bedarf Runtime- oder Modell-Assets herunterladen
- `gebuendelter Installer`: enthaelt Python und FFmpeg
- `offline-bundled ... allmodels Installer`: enthaelt die gebuendelten Runtime-Payloads, die fuer eine vollstaendig offline abschliessbare Installation fuer das Ziel-Backend noetig sind

## Offline-allmodels-Varianten

Wenn du einen Offline-allmodels-Installer heruntergeladen hast, zeigt der Dateiname das gebuendelte Backend an:

- `offline-bundled-cpu-allmodels`: CPU-Drum-Kit-Runtime und Offline-Modelle
- `offline-bundled-nvidia-gpu-allmodels`: NVIDIA/CUDA-Drum-Kit-Runtime und Offline-Modelle
- `offline-bundled-amd-gpu-allmodels`: DirectML-Drum-Kit-Runtime und Offline-Modelle

Diese Installer sollen die Einrichtung fuer ihre Ziel-Runtime vollstaendig offline nur aus den gebuendelten Wheels und Payloads abschliessen koennen.

## Naechste Schritte

1. Starte REAPER.
2. Fuehre `STEMwerk: Setup` aus, wenn du die Runtime pruefen oder reparieren willst.
3. Nutze `Check only`, um den Runtime-Zustand zu verifizieren.
4. Starte `Stemwerk: Main` aus dem Actions-Menue fuer die normale Nutzung.
5. Wenn Aktionen fehlen, lade Skripte aus `REAPER/Scripts/STEMwerk-reaper/`.
6. `STEMwerk_Setup_Toolbar.lua` ist optional, wenn du Toolbar-Kurzbefehle moechtest.

## Setup und Reparatur

Nutze `STEMwerk: Setup` fuer:

- `Check only`
- `Repair`
- `Rebuild venv`
- `Save Support Bundle`
- `Open logs folder`
- `Open runtime folder`

Fuehre den Installer vor allem dann erneut aus, wenn die installierte Skript-Payload fehlt oder beschaedigt ist, oder wenn du gebuendelte Payloads erneut installieren willst.

Die Deinstallation entfernt STEMwerk-Runtime-Daten und installierte STEMwerk-REAPER-Skripte.

## Wenn etwas fehlt

1. Starte `STEMwerk: Setup`.
2. Klicke auf `Check only`.
3. Nutze `Repair` oder `Rebuild venv`, wenn das empfohlen wird.
4. Nutze `Open logs folder` fuer tiefere Fehlersuche.
5. Nutze `Save Support Bundle`, wenn du Hilfe anforderst.
6. Fuehre den Installer nur erneut aus, wenn die Installations-Payload selbst fehlt oder beschaedigt ist.

## Support Bundles

Support Bundles werden hier gespeichert:

`%APPDATA%\REAPER\STEMwerk-support-bundles\`

Jeder Speichervorgang erzeugt beides:

- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS\`
- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS.zip`

Fuege die `.zip`-Datei bei, wenn du Support kontaktierst.

Ein Support Bundle enthaelt, soweit verfuegbar:

- Bootstrap-/Runtime-Logs
- State-/Capabilities-Dateien
- aktuelle Run-Logs/Artefakte
- `support_bundle_timings.txt`
- `processing_summary.txt`

Support Bundles schliessen Audio-, Modell-, Wheel-, Binary- und Runtime-Payload-Dateien bewusst aus.

## Parallel vs Sequential (Multi-track)

STEMwerk kann Multi-Track-Jobs parallel verarbeiten, wenn Parallel aktiviert ist und das gewaehlte Backend/Job-Layout das unterstuetzt.

Zur Stabilitaet kann es auf Sequential zurueckfallen, je nach Backend, Geraetewahl, Job-Layout, Time Selection/Item-Isolation oder wenn nur ein Job in der Warteschlange steht.

Das Fortschrittsfenster zeigt den aktiven Modus und den Fallback-Grund an.

## Setup-Log oeffnen

Bootstrap-/Setup-Log:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Nutze die Setup-Aktionsknopfe, um Logs oder Runtime-Ordner direkt zu oeffnen.

## Welche Skripte du normal nutzt

Normale Nutzung:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` fuer ausgewaehlte Multi-Take-Items

Support und Reparatur:

- `STEMwerk: Setup`
- `STEMwerk: Save Support Bundle`

Optionaler Komfort:

- `STEMwerk_Setup_Toolbar.lua`
