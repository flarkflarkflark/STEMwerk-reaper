# STEMwerk Apple Silicon snelle test

## Doel

Met deze test willen we snel controleren of STEMwerk goed werkt op je Apple Silicon Mac.

We checken vooral:

- of Python native op Apple Silicon draait
- of torch/MPS beschikbaar is
- of FFmpeg wordt gevonden
- of één korte stem-separation werkt
- of de support bundle bruikbare diagnostics bevat

## Voor je begint

- REAPER is al geïnstalleerd.
- Gebruik het meegeleverde STEMwerk testpakket.
- Gebruik een kort audiobestand van ongeveer 10–30 seconden.
- Stuur geen audiofiles terug, tenzij ik daar expliciet om vraag.

## Stap 1 — STEMwerk installeren/updaten

1. Pak het testpakket uit.
2. Kopieer/installeer STEMwerk volgens de meegeleverde instructies.
3. Open REAPER.
4. Ga naar `Actions > Show action list`.
5. Zoek op `STEMwerk`.
6. Start `STEMwerk-SETUP.lua`.

## Stap 2 — Eerste setup

Start eerst gewoon `STEMwerk-SETUP.lua` en volg het setup-venster.

Begin niet meteen met Repair, tenzij de setup daarom vraagt of de eerste setup niet netjes afrondt.

Goede signalen op Apple Silicon zijn bijvoorbeeld:

- `mac_arch=arm64`
- `python platform.machine=arm64`
- `torch=2.5.1`
- `torchaudio=2.5.1`
- `mps_built=True`
- `mps_available=True`

Als Python/MPS faalt:

1. Stop met testen.
2. Maak een Support Bundle.
3. Stuur de Support Bundle plus een korte beschrijving terug.

## Stap 3 — FFmpeg

STEMwerk heeft FFmpeg nodig.

Goed resultaat:

- FFmpeg wordt automatisch gevonden

of:

- STEMwerk toont duidelijk `Missing FFmpeg` / `FFmpeg ontbreekt`

Als FFmpeg ontbreekt en je Homebrew gebruikt:

```bash
brew install ffmpeg
which ffmpeg
```

Veelvoorkomend pad op Apple Silicon:

- `/opt/homebrew/bin/ffmpeg`

Als FFmpeg al geïnstalleerd is op een andere plek:

- gebruik `Set FFmpeg Path...`
- draai daarna setup opnieuw

## Stap 4 — Korte separation test

1. Open of importeer één kort audiobestand.
2. Selecteer één item.
3. Kies bijvoorbeeld `Vocals` of een snelle mode.
4. Zet output op `New Tracks`.
5. Start separation.

Verwacht:

- geen crash
- er verschijnt een output-stemtrack
- je kunt daarna een Support Bundle opslaan

## Stap 5 — Optioneel: twee clips

Alleen doen als stap 4 goed gaat:

1. Selecteer 2 korte clips.
2. Gebruik dezelfde modelkeuze.
3. Laat output op `New Tracks` staan.
4. Controleer of beide clips verwerkt worden.

## Stap 6 — Support Bundle opslaan

Doe dit altijd aan het einde, ook als alles goed lijkt.

Gebruik `Save Support Bundle` vanuit de setup/support-flow.

Verwacht:

- je ziet een korte busy/status melding tijdens verzamelen
- support bundle wordt aangemaakt
- runtime diagnostics zitten erin
- geen audio/project/model files nodig

## Wat Dimitri terugstuurt

Graag alleen dit:

1. Mac model/chip
2. macOS versie
3. REAPER versie
4. Setup resultaat: PASS/FAIL
5. FFmpeg resultaat:
   - automatisch gevonden?
   - welk pad gebruikt?
   - handmatig gezet via Set FFmpeg Path?
6. MPS resultaat:
   - `mps_built`
   - `mps_available`
7. Separation resultaat:
   - PASS/FAIL
   - welke modelkeuze
   - globale verwerkingstijd
8. Support Bundle (zip/map)
9. Alleen bij zichtbare fout: een screenshot

## Niet terugsturen

- audiofiles
- REAPER projecten
- modelfiles
- grote geplakte logs als support bundle beschikbaar is

## Snelle storingsroute

- `Missing FFmpeg`:
  - installeer FFmpeg of gebruik Set FFmpeg Path
  - draai setup opnieuw
- x86_64/Rosetta Python op Apple Silicon:
  - stop test
  - stuur support bundle
- torch/MPS niet beschikbaar:
  - stop test
  - stuur support bundle
- separation faalt na setup PASS:
  - stuur support bundle + korte beschrijving

## Belangrijke noot

- Verbose `pip` output is normaal.
- Downloads kunnen even duren.
- Support bundle maken kan een paar seconden kosten.
- `Missing FFmpeg` betekent niet dat Apple Silicon/MPS kapot is.
