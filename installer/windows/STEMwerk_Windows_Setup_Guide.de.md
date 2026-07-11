# STEMwerk Windows-Setup-Anleitung

Diese Anleitung gilt fuer den Windows-Installer von STEMwerk 2.3.0.4.

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
2. Wenn die `STEMwerk`-Aktionen bereits sichtbar sind, fuehre `STEMwerk: Setup` aus, wenn du die Runtime pruefen oder reparieren willst.
3. Nutze `Check only`, um den Runtime-Zustand zu verifizieren.
4. Starte `Stemwerk: Main` aus dem Actions-Menue fuer die normale Nutzung.
5. Wenn `STEMwerk`-Aktionen fehlen, oeffne `Actions -> Show action list -> ReaScript: Load...`.
6. Bevorzugter Helfer fuer die einmalige Registrierung:
   `C:\Users\<Username>\AppData\Roaming\REAPER\Scripts\STEMwerk-reaper\STEMwerk_Setup_Toolbar.lua`
7. Dieser Helfer registriert die normalen STEMwerk-Aktionen in REAPER. Wenn du nur die Aktionen brauchst, kannst du den spaeteren Toolbar-Dialog abbrechen.

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

1. Pruefe zuerst, ob dieser Skript-Ordner existiert:
   `%APPDATA%\REAPER\Scripts\STEMwerk-reaper`
2. Wenn der Ordner existiert, aber keine `STEMwerk`-Aktionen erscheinen, hat REAPER die Skripte noch nicht registriert.
3. Oeffne in REAPER `Actions -> Show action list -> ReaScript: Load...`.
4. Bevorzugter Helfer fuer die einmalige Registrierung:
   `STEMwerk_Setup_Toolbar.lua`
5. Wenn du den Helfer nicht verwenden willst, lade nur:
   `STEMwerk-SETUP.lua`, `STEMwerk.lua`, `STEMwerk_Drum_Kit_Split.lua`, `STEMwerk_Explode_Takes.lua`
6. Lade nicht einfach jede `.lua`-Datei in diesem Ordner.
7. Lade keine Dateien unter `_internal\`.
8. `STEMwerk_AI_Separate.lua` ist nur ein Kompatibilitaets-Wrapper fuer aeltere Installationen und wird bei einer frischen Installation nicht benoetigt.
9. Fuehre nach der Registrierung `STEMwerk: Setup` aus, klicke auf `Check only` und nutze danach `Repair` oder `Rebuild venv`, wenn das empfohlen wird.
10. Nutze `Open logs folder` oder `Save Support Bundle`, wenn du Hilfe anforderst.
11. Fuehre den Installer nur erneut aus, wenn die Installations-Payload selbst fehlt oder beschaedigt ist.

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

- `STEMwerk: Setup`
- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Drum Kit Split`
- `Stemwerk: Explode Takes (In Place)` fuer ausgewaehlte Multi-Take-Items

Support und Reparatur:

- `STEMwerk: Save Support Bundle`

Optionaler Komfort:

- `STEMwerk_Setup_Toolbar.lua`

Kompatibilitaets-Wrapper:

- `STEMwerk_AI_Separate.lua` bleibt erhalten, damit aeltere REAPER-Action-Bindings nicht brechen, aber neue Installationen sollten `STEMwerk.lua` verwenden.
