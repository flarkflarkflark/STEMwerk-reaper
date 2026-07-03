# STEMwerk Windows Setup-handleiding

Deze handleiding hoort bij de Windows-installer van STEMwerk 2.3.0.0.

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
- `offline-bundled-nvidia-allmodels`: NVIDIA/CUDA Drum Kit-runtime en offline modellen
- `offline-bundled-amd-allmodels`: DirectML Drum Kit-runtime en offline modellen

Deze installers zijn bedoeld om volledig offline te kunnen afronden met alleen de meegeleverde wheels en payloads voor hun doel-runtime.

## Wat je nu doet

1. Start REAPER.
2. Voer `STEMwerk: Setup` uit als je de runtime wilt controleren of herstellen.
3. Gebruik `Check only` om de runtime te verifieren.
4. Start `Stemwerk: Main` vanuit het Actions-menu voor normaal gebruik.
5. Als acties ontbreken, laad dan scripts uit `REAPER/Scripts/STEMwerk-reaper/`.
6. `STEMwerk_Setup_Toolbar.lua` is optioneel als je toolbar-snelkoppelingen wilt.

## Setup en herstel

Gebruik `STEMwerk: Setup` voor:

- `Check only`
- `Repair`
- `Rebuild venv`
- `Save Support Bundle`
- `Open logs folder`
- `Open runtime folder`

Voer de installer vooral opnieuw uit als de geinstalleerde scriptpayload ontbreekt of beschadigd is, of als je meegeleverde payloads opnieuw wilt installeren.

De-installeren verwijdert STEMwerk-runtime-data en geinstalleerde STEMwerk REAPER-scripts.

## Wanneer er iets ontbreekt

1. Run `STEMwerk: Setup`.
2. Klik op `Check only`.
3. Gebruik `Repair` of `Rebuild venv` als dat wordt aangeraden.
4. Gebruik `Open logs folder` voor diepere troubleshooting.
5. Gebruik `Save Support Bundle` als je hulp vraagt.
6. Voer de installer alleen opnieuw uit als de installatiepayload zelf ontbreekt of beschadigd is.

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

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` voor geselecteerde multi-take-items

Support en herstel:

- `STEMwerk: Setup`
- `STEMwerk: Save Support Bundle`

Optioneel gemak:

- `STEMwerk_Setup_Toolbar.lua`
