# Arch Linux Testing Guide - STEMwerk v2.2.0

Dit document helpt je bij het testen van de v2.2.0 "Yeah Yeah" release zodra je bent overgeschakeld naar Arch Linux.

## 1. Voorbereiding
Zorg dat de benodigde systeem-packages aanwezig zijn:
```bash
sudo pacman -S yt-dlp ffmpeg python
```

## 2. Repository Sync
Zorg dat je lokale kloon op Arch de v2.2.0 tag gebruikt:
```bash
# In je STEMwerk-reaper map
git fetch origin
git checkout v2.2.0
```

## 3. Test Audio (Bossa Test)
Voer de volgende commando's uit om de testbestanden als FLAC te genereren:
```bash
mkdir -p ~/Music/Bossa_Test
cd ~/Music/Bossa_Test

# Georgie Fame (1964)
yt-dlp -x --audio-format flac "ytsearch1:Georgie Fame Yeh Yeh official audio" -o "Georgie_Fame_Yeh_Yeh.flac"

# Matt Bianco (1985)
yt-dlp -x --audio-format flac "ytsearch1:Matt Bianco Yeh Yeh" -o "Matt_Bianco_Yeh_Yeh.flac"
```

## 4. Testen in REAPER
1. Open REAPER en laad de twee bestanden op aparte tracks.
2. Controleer of de **footer** correct rapporteert bij een tijdselectie over beide tracks.
3. Controleer of de **GPU** (AMD/ROCm) correct wordt getoond in het progress-venster.
4. Verifieer dat de **Help-tabs** (F1) goed leesbaar zijn.

## 5. Tidal Links
- [Georgie Fame - Yeh, Yeh](https://tidal.com/browse/track/1911431)
- [Matt Bianco - Yeh Yeh](https://tidal.com/browse/track/2545124)

Veel plezier met de Bossa Nova! 🎶🚀
