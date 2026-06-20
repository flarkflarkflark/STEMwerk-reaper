# STEMwerk Windows-Setup-Anleitung

Diese Anleitung gilt für den Windows-Installer-Build von STEMwerk.

## Was der Installer gerade gemacht hat

Der Windows-Installer hat:

- die STEMwerk REAPER-Skripte in deinen REAPER Scripts-Ordner kopiert
- die STEMwerk-Runtime in deinem lokalen Windows-Profil vorbereitet
- die von STEMwerk verwendete Python-Umgebung erstellt oder aktualisiert
- FFmpeg geprüft und die zentralen Python-Pakete installiert

Im normalen Windows-Ablauf ist dieser Installer der Bootstrap-Schritt.

## Installer-Terminologie

- `Offline-Installer`: kleiner Installer/Downloader, der benoetigte Runtime- oder Modell-Komponenten noch aus dem Internet laden kann
- `gebuendelter Installer`: enthaelt Python und FFmpeg
- `vollstaendiger Offline-Installer`: Komplettpaket fuer Installation/Nutzung ohne Internet

## Vollstaendige Offline-Installer-Varianten (GPU)

Wenn du einen vollstaendigen Offline-/bundled Installer heruntergeladen hast, zeigt der Dateiname, welche GPU-Runtime enthalten ist:

- `offline-bundled-nvidia`: CUDA-Wheels für NVIDIA-GPUs.
- `offline-bundled-amd`: DirectML-Wheels für AMD/Intel-GPUs.

Wenn der Installer keine GPU-Runtime verifizieren kann, fällt STEMwerk auf CPU zurück.

Offline-NVIDIA-Hinweis (Kontext Issue #11):
- Wenn Processing online funktioniert, offline aber fehlschlägt, prüfen, ob Modelle unter `%LOCALAPPDATA%\\STEMwerk\\models` vorhanden sind.
- Bestehende `allmodels`-Full-Offline-Assets werden derzeit fuer den Demucs/Core-Modell-Cache verwendet.
- In bundled/offline Installern ist die Vorab-Option "Modell-Cache bereinigen" bewusst deaktiviert, damit frisch gebündelte Modell-Payloads nicht gelöscht werden.
- In der 2.3-Release-Linie sind das keine vollstaendigen DrumSep/Drum-Kit-Offline-Bundles; DrumSep-Runtime und Modell-Assets laufen weiter ueber den Setup-/Runtime-Pfad, sofern eine spezifische Full-Offline-Asset-Beschreibung nicht ausdruecklich etwas anderes sagt.

## Nächste Schritte

1. REAPER öffnen.
2. Die Action List öffnen.
3. Falls STEMwerk noch nicht sichtbar ist: `Actions -> ReaScript -> Load ReaScript...`.
4. Zu `REAPER/Scripts/STEMwerk-reaper/` wechseln.
5. `STEMwerk.lua` laden.
6. `Stemwerk: Main` ausführen.

Optional:

- `STEMwerk_Setup_Toolbar.lua` laden, um die Standard-STEMwerk-Aktionen in der Action List zu registrieren.
- Die Quick-Presets laden, wenn du One-Click-Aktionen wie Karaoke, Vocals Only, Drums Only, Bass Only oder All Stems willst.

## Wichtiger Windows-Hinweis

Unter Windows ersetzt `STEMwerk-SETUP.lua` nicht den Installer-Bootstrap.

Wenn etwas fehlt oder die Runtime unvollständig ist:

1. zuerst den Windows-Installer erneut ausführen
2. danach bei Bedarf das Setup-Log prüfen

## Parallel vs Sequential (Multi-track)

STEMwerk kann Multi-Track-Jobs parallel ausführen, wenn Parallel aktiviert ist und mehr als ein Job in der Warteschlange steht.

Es fällt automatisch auf Sequential zurück, wenn:

- Gerät = explizit `DirectML` und mehr als ein Job in der Warteschlange steht
- Gerät = `auto` und kein GPU-Backend verfügbar ist
- die Time-Selection-Verarbeitung die Arbeit in getrennte per-item Jobs aufteilt
- nur 1 Job in der Warteschlange steht

Beispiele, in denen wirklich parallel verarbeitet wird:

- Du wählst 3 Tracks mit Items, keine Time Selection, Parallel an, Gerät = `cuda:0`. -> 3 Jobs gleichzeitig (pro Track).
- Du wählst 5 Tracks, Parallel an, Gerät = `auto`, und eine GPU wird erkannt. -> 5 Jobs gleichzeitig.
- Du wählst mehrere Items über mehrere Tracks (keine Time Selection), Parallel an, Gerät = `cuda`. -> per-Track Jobs parallel.

Beispiele, in denen es nicht parallel läuft:

- Parallel an, Gerät = explizit `DirectML`, mehr als ein Job in der Warteschlange -> Sequential-Fallback ("DirectML multi-track stability mode").
- Time Selection mit mehreren Items auf einem Track -> per-item Jobs -> Sequential-Fallback ("Per-item multi-track isolation").
- Parallel an, Gerät = `auto`, aber kein GPU-Backend -> Sequential-Fallback ("Auto device, no GPU").
- Nur 1 Job (1 Track) -> per Definition sequential.

Das Fortschrittsfenster zeigt den aktiven Modus und den Grund bei einem Fallback.

## Setup-Log öffnen

Das Setup-Log liegt unter:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Nutze es, wenn das Setup fehlgeschlagen ist, FFmpeg nicht erkannt wurde oder Runtime-Pakete nicht fertig installiert wurden.

## Welche Skripte du normal nutzt

Normale Nutzung:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` (für ausgewählte Multi-Take-Items)

Support-/Reparaturpfade:

- `STEMwerk: Setup`

## Wann Setup verwenden

Unter Windows `STEMwerk: Setup` nur als REAPER-seitigen Support-/Reparaturpfad nach der Installation verwenden.

Für eine frische Windows-Installation ist der Installer der richtige Setup-Weg.
