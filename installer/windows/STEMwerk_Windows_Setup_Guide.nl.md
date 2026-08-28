# STEMwerk Windows Setup-handleiding

Deze handleiding hoort bij de Windows-installer van STEMwerk 2.3.1.0.

## Wat de installer zojuist heeft gedaan

De Windows-installer heeft:

- de STEMwerk REAPER-scripts geinstalleerd
- de STEMwerk-runtime voorbereid onder `%LOCALAPPDATA%\STEMwerk`
- de Python-omgeving van STEMwerk aangemaakt of bijgewerkt
- FFmpeg en de kernpakketten van de runtime gecontroleerd
- meegeleverde Drum Kit-runtime en offline modelpayloads geinstalleerd wanneer die in deze installer zitten

De Windows-installer blijft de aanbevolen route voor een eerste installatie en voor herstel op Windows.

## Installertypen

- `online installer`: kleinere installer; die kan runtime- of modelassets downloaden wanneer dat nodig is
- `bundled installer`: bevat Python en FFmpeg
- `offline-bundled ... allmodels installer`: bevat de meegeleverde runtimepayloads die nodig zijn voor een volledig offline installatie voor de doel-backend

## Offline allmodels-varianten

Als je een offline allmodels-installer hebt gedownload, geeft de bestandsnaam de meegeleverde backend aan:

- `offline-bundled-cpu-allmodels`: CPU Drum Kit-runtime en offline modellen
- `offline-bundled-nvidia-gpu-allmodels`: NVIDIA/CUDA Drum Kit-runtime en offline modellen
- `offline-bundled-amd-gpu-allmodels`: DirectML Drum Kit-runtime en offline modellen

Deze installers zijn bedoeld om volledig offline te kunnen afronden met alleen de meegeleverde wheels en payloads voor hun doel-runtime.

## Wat je nu doet

1. Start REAPER.
2. Als de `STEMwerk`-acties al zichtbaar zijn, voer dan `STEMwerk: Setup` uit als je de runtime wilt controleren.
3. Gebruik `Check only` om de runtime te verifieren.
4. Start `Stemwerk: Main` vanuit het Actions-menu voor normaal gebruik.
5. Als `STEMwerk`-acties ontbreken, open dan `Actions -> Show action list -> ReaScript: Load...`.
6. Voorkeurshelper voor eenmalige registratie:
   `C:\Users\<Username>\AppData\Roaming\REAPER\Scripts\STEMwerk-reaper\STEMwerk_Setup_Toolbar.lua`
7. Die helper registreert de normale STEMwerk-acties in REAPER. Als je alleen de acties nodig hebt, kun je de latere toolbar-prompt annuleren.

## Setup en herstel

Op Windows worden installatie, update en herstel afgehandeld door de STEMwerk-installer, niet door `STEMwerk: Setup` binnen REAPER. Gebruik `STEMwerk: Setup` alleen voor:

- `Check only`
- `Save Support Bundle`
- `Open logs folder`
- `Open runtime folder`

Als `Check only` een probleem meldt, voer dan dezelfde STEMwerk-installer (online of bundled) opnieuw uit die je eerder gebruikte; die herstelt de runtime ter plekke. Voer de installer ook opnieuw uit als de geinstalleerde scriptpayload ontbreekt of beschadigd is, of als je meegeleverde payloads opnieuw wilt installeren.

De-installeren verwijdert STEMwerk-runtime-data en geinstalleerde STEMwerk REAPER-scripts.

## Wanneer er iets ontbreekt

1. Controleer eerst of deze scriptmap bestaat:
   `%APPDATA%\REAPER\Scripts\STEMwerk-reaper`
2. Als die map bestaat maar er geen `STEMwerk`-acties zichtbaar zijn, heeft REAPER de scripts nog niet geregistreerd.
3. Open in REAPER `Actions -> Show action list -> ReaScript: Load...`.
4. Voorkeurshelper voor eenmalige registratie:
   `STEMwerk_Setup_Toolbar.lua`
5. Als je de helper niet wilt gebruiken, laad dan alleen:
   `STEMwerk-SETUP.lua`, `STEMwerk.lua`, `STEMwerk_Drum_Kit_Split.lua`, `STEMwerk_Explode_Takes.lua`
6. Laad niet zomaar elk `.lua`-bestand in deze map.
7. Laad geen bestanden uit `_internal\`.
8. `STEMwerk_AI_Separate.lua` is alleen een compatibiliteitswrapper voor oudere installs en is niet nodig bij een verse installatie.
9. Voer na registratie `STEMwerk: Setup` uit en klik op `Check only`. Meldt dat een probleem, voer dan de STEMwerk-installer opnieuw uit om de runtime te herstellen.
10. Gebruik `Open logs folder` of `Save Support Bundle` als je hulp vraagt.
11. Voer de installer alleen opnieuw uit als de installatiepayload zelf ontbreekt of beschadigd is.

## Support bundles

Support bundles worden opgeslagen in:

`%APPDATA%\REAPER\STEMwerk-support-bundles\`

Elke save maakt allebei aan:

- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS\`
- `STEMwerk-support-bundle-YYYYMMDD-HHMMSS.zip`

Voeg het `.zip`-bestand toe wanneer je support vraagt.

Een support bundle bevat waar beschikbaar:

- bootstrap/runtime-logs
- state/capabilities-bestanden
- recente run-logs/artifacts
- `support_bundle_timings.txt`
- `processing_summary.txt`

Support bundles sluiten audio-, model-, wheel-, binary- en runtimepayloadbestanden bewust uit.

## Parallel vs Sequential (Multi-track)

STEMwerk kan multi-track-jobs parallel verwerken wanneer Parallel aan staat en de gekozen backend/jobindeling dat ondersteunt.

Voor stabiliteit kan het terugvallen op Sequential, afhankelijk van backend, apparaatkeuze, jobindeling, tijdselectie/item-isolatie, of wanneer er maar een job in de wachtrij staat.

Het voortgangsvenster toont de actieve modus en de fallbackreden wanneer zo'n fallback gebeurt.

## Open de setup-log

Bootstrap/setup-log:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Gebruik de Setup-knoppen om logs of runtime-mappen direct te openen.

## Welke scripts je normaal gebruikt

Normaal gebruik:

- `STEMwerk: Setup`
- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Drum Kit Split`
- `Stemwerk: Explode Takes (In Place)` voor geselecteerde multi-take-items

Support en herstel:

- `STEMwerk: Save Support Bundle`

Optioneel gemak:

- `STEMwerk_Setup_Toolbar.lua`

Compatibiliteitswrapper:

- `STEMwerk_AI_Separate.lua` blijft bestaan zodat oudere REAPER-action bindings niet breken, maar nieuwe installs moeten `STEMwerk.lua` gebruiken.
