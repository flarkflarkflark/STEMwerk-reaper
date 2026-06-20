# STEMwerk Windows Setup-handleiding

Deze handleiding is voor de Windows-installerbuild van STEMwerk.

## Wat de installer zojuist heeft gedaan

De Windows-installer heeft:

- de STEMwerk REAPER-scripts naar je REAPER Scripts-map gekopieerd
- de STEMwerk-runtime onder je lokale Windows-profiel voorbereid
- de Python-omgeving die STEMwerk gebruikt aangemaakt of bijgewerkt
- FFmpeg gecontroleerd en de kernpakketten voor Python geïnstalleerd

In de normale Windows-flow is deze installer de bootstrap-stap.

## Offline installer-varianten (GPU)

Als je een offline bundled installer hebt gedownload, vertelt de bestandsnaam welke GPU-runtime is meegeleverd:

- `offline-bundled-nvidia`: CUDA-wheels voor NVIDIA-GPU's.
- `offline-bundled-amd`: DirectML-wheels voor AMD/Intel-GPU's.

Als de installer geen GPU-runtime kan verifiëren, valt STEMwerk terug op CPU.

Offline NVIDIA-opmerking (context issue #11):
- Als processing online wel werkt maar offline niet, controleer of modellen aanwezig zijn in `%LOCALAPPDATA%\\STEMwerk\\models`.
- Offline bundled installers worden nu alleen als `allmodels`-varianten uitgebracht voor de Demucs/core-modelcache.
- In bundled/offline installers is de pre-setup optie "modelcache opschonen" bewust uitgeschakeld om net meegeleverde modelpayloads niet te verwijderen.
- Dit zijn in de 2.3-release geen complete offline DrumSep/Drum Kit-bundels; DrumSep-runtime en modelassets lopen via de setup/runtime-route.

## Wat je nu doet

1. Open REAPER.
2. Open de Action List.
3. Als STEMwerk nog niet zichtbaar is, gebruik `Actions -> ReaScript -> Load ReaScript...`.
4. Ga naar `REAPER/Scripts/STEMwerk-reaper/`.
5. Laad `STEMwerk.lua`.
6. Start `Stemwerk: Main`.

Optioneel:

- Laad `STEMwerk_Setup_Toolbar.lua` om de standaard STEMwerk-actions in de Action List te registreren.
- Laad de snelle presets als je one-click acties wilt zoals Karaoke, Vocals Only, Drums Only, Bass Only of All Stems.

## Belangrijke Windows-opmerking

Op Windows vervangt `STEMwerk-SETUP.lua` de installer-bootstrap niet.

Als er iets ontbreekt of de runtime onvolledig is:

1. voer eerst de Windows-installer opnieuw uit
2. controleer daarna zo nodig de setup-log

## Parallel vs Sequential (Multi-track)

STEMwerk kan multi-track jobs parallel uitvoeren wanneer Parallel aan staat en er meer dan één job in de wachtrij staat.

Het valt automatisch terug naar Sequential wanneer:

- apparaat = expliciet `DirectML` en er meer dan één job in de wachtrij staat
- apparaat = `auto` en er geen GPU-backend beschikbaar is
- tijdselectie-verwerking het werk splitst in losse per-item jobs
- er maar 1 job in de wachtrij staat

Voorbeelden waar echt parallel wordt uitgevoerd:

- Je selecteert 3 tracks met items, geen tijdselectie, Parallel aan, apparaat = `cuda:0`. -> 3 jobs tegelijk (per track).
- Je selecteert 5 tracks, Parallel aan, apparaat = `auto`, en er wordt een GPU gedetecteerd. -> 5 jobs tegelijk.
- Je selecteert meerdere items over meerdere tracks (geen tijdselectie), Parallel aan, apparaat = `cuda`. -> per-track jobs parallel.

Voorbeelden waar het niet parallel draait:

- Parallel aan, apparaat = expliciet `DirectML`, meer dan één job in de wachtrij -> sequential fallback ("DirectML multi-track stability mode").
- Tijdselectie met meerdere items op één track -> per-item jobs -> sequential fallback ("Per-item multi-track isolation").
- Parallel aan, apparaat = `auto`, maar geen GPU-backend -> sequential fallback ("Auto device, no GPU").
- Slechts 1 job (1 track) -> per definitie sequential.

Het voortgangsvenster toont de actieve modus en de reden wanneer een fallback gebeurt.

## Open de setup-log

De setup-log staat op:

`%LOCALAPPDATA%\STEMwerk\logs\bootstrap.log`

Gebruik deze als setup is mislukt, FFmpeg niet is gedetecteerd of runtime-pakketten niet volledig zijn geïnstalleerd.

## Welke scripts je normaal gebruikt

Normaal gebruik:

- `Stemwerk: Main`
- `Stemwerk: Karaoke`
- `Stemwerk: Vocals Only`
- `Stemwerk: Drums Only`
- `Stemwerk: Bass Only`
- `Stemwerk: All Stems`
- `Stemwerk: Explode Takes (In Place)` (voor geselecteerde multi-take items)

Support-/herstelpaden:

- `STEMwerk: Setup`

## Wanneer Setup gebruiken

Gebruik op Windows `STEMwerk: Setup` alleen als REAPER-side support- of herstelpad na installatie.

Voor een verse Windows-installatie is de installer de juiste setup-route.
