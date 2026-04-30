#!/usr/bin/env python3
from pathlib import Path
import textwrap

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "docs" / "readme"
ASSET_DIR = ROOT / "build" / "readme_pdf_assets"

PAGE_W, PAGE_H = 1240, 1754
MARGIN = 82
CONTENT_W = PAGE_W - (MARGIN * 2)

FONT_DIR = Path("/usr/share/fonts/truetype/dejavu")
FONT_REG = str(FONT_DIR / "DejaVuSans.ttf")
FONT_BOLD = str(FONT_DIR / "DejaVuSans-Bold.ttf")


def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)


F = {
    "title": font(54, True),
    "subtitle": font(25),
    "h1": font(32, True),
    "h2": font(24, True),
    "body": font(21),
    "small": font(17),
    "tiny": font(15),
    "label": font(18, True),
}


COL = {
    "bg": (250, 251, 253),
    "ink": (24, 29, 36),
    "muted": (85, 95, 108),
    "line": (218, 224, 232),
    "panel": (255, 255, 255),
    "accent": (76, 132, 255),
    "accent2": (238, 96, 89),
    "green": (70, 180, 105),
    "orange": (235, 136, 45),
}


DATA = {
    "en": {
        "file": "README_en.pdf",
        "title": "STEMwerk for REAPER",
        "subtitle": "Local stem separation with selected tracks, media items, time selections and takes.",
        "page1": "Global Workflow",
        "intro": [
            "STEMwerk separates vocals, drums, bass, other, and optional guitar/piano stems inside REAPER.",
            "Processing is local. The first run may need setup, backend packages, and model downloads.",
        ],
        "steps": [
            ("1. Install or update", "Use the Windows installer, or ReaPack on macOS/Linux. Run STEMwerk-SETUP.lua when setup, repair, or dependency checks are needed."),
            ("2. Choose the source", "Select media items, selected tracks, or a time selection. The active REAPER selection determines what STEMwerk will process."),
            ("3. Choose model, stems and device", "Pick Fast, Quality, or 6-Stem; choose vocals/drums/bass/other; use Auto unless you need a specific CPU/GPU backend."),
            ("4. Choose output", "Create new stem tracks, group them in folders, or write stems in-place as takes on the source item."),
            ("5. Start and review", "Click STEMwerk, follow the progress window, then check the created tracks, items or takes in REAPER."),
        ],
        "page2": "Working With REAPER Sources",
        "source_intro": "Use the source type that matches the edit you already made in REAPER:",
        "top_icons_title": "Top-right icons",
        "top_icons": [
            "Language: switch the STEMwerk UI language.",
            "Tooltips: show or hide hover explanations.",
            "Day/night: switch between light and dark mode.",
            "FX: enable or disable visual effects/art animation.",
        ],
        "sources": [
            ("Time selection", "Use a loop/time selection when you want only a region. If no items or tracks are selected, STEMwerk can process that range."),
            ("Media items", "Select one or more media items to process complete items. Items can be on one track or across multiple tracks."),
            ("Tracks", "Select tracks when you want STEMwerk to process the material on those tracks and return stems as new tracks or folders."),
            ("Takes / in-place", "Use in-place output to add stems as takes, then use Explode Takes to split selected multi-take items into tracks, in-place items, or ordered items."),
        ],
        "page3": "Setup, Backends and Updates",
        "shortcuts_title": "Keyboard Shortcuts",
        "main_shortcuts_title": "Main window",
        "main_shortcuts": [
            ("Enter/Space", "Start separation"),
            ("ESC", "Close or cancel"),
            ("F1", "Open Help & Art Gallery"),
            ("1-6", "Toggle stems: Vocals, Drums, Bass, Other, Guitar, Piano"),
            ("K/I/A", "Karaoke/Instrumental, All stems"),
            ("V/D/B/O/P/G", "Preset: Vocals, Drums, Bass, Other, Piano, Guitar"),
            ("F/Q/S", "Model: Fast, Quality, 6-Stem"),
            ("+/-", "Resize the main window"),
        ],
        "help_shortcuts_title": "Help / Gallery",
        "help_shortcuts": [
            ("Enter", "Start from Help or close completion"),
            ("Space", "Generate new art"),
            ("Left/Right", "Switch tabs"),
            ("Wheel/drag", "Zoom, pan, rotate, or move content"),
            ("Double-click", "Reset view"),
        ],
        "notes": [
            ("Windows", "Use the installer for normal setup. ReaPack only installs scripts and is not the recommended first-time Windows setup path."),
            ("macOS / Linux", "Install with ReaPack, then run STEMwerk-SETUP.lua for first setup or repair. Existing working venvs usually do not need setup after every update."),
            ("CPU/GPU", "Auto chooses the best detected backend. CPU is the safest fallback. CUDA, DirectML, ROCm and MPS depend on hardware, drivers and Python packages."),
            ("First run", "Creating the venv, installing packages and downloading the selected model can take several minutes. Later runs are normally faster."),
            ("Troubleshooting", "If STEMwerk reports missing Python, FFmpeg, backend packages or a broken venv, run STEMwerk-SETUP.lua again and check the shown logs."),
        ],
    },
    "nl": {
        "file": "README_nl.pdf",
        "title": "STEMwerk voor REAPER",
        "subtitle": "Lokale stem-separatie met geselecteerde tracks, media-items, tijdselecties en takes.",
        "page1": "Globale Werkwijze",
        "intro": [
            "STEMwerk scheidt vocals, drums, bass, other en optioneel guitar/piano direct in REAPER.",
            "Alles draait lokaal. De eerste run kan setup, backend packages en model-downloads nodig hebben.",
        ],
        "steps": [
            ("1. Installeer of update", "Gebruik de Windows installer, of ReaPack op macOS/Linux. Draai STEMwerk-SETUP.lua bij setup, reparatie of dependency checks."),
            ("2. Kies de bron", "Selecteer media-items, tracks of een tijdselectie. De actieve REAPER selectie bepaalt wat STEMwerk verwerkt."),
            ("3. Kies model, stems en device", "Kies Fast, Quality of 6-Stem; selecteer vocals/drums/bass/other; gebruik Auto tenzij je bewust CPU/GPU wilt forceren."),
            ("4. Kies output", "Maak nieuwe stem-tracks, groepeer ze in folders, of schrijf stems in-place als takes op het bron-item."),
            ("5. Start en controleer", "Klik STEMwerk, volg het voortgangsvenster en controleer daarna de aangemaakte tracks, items of takes in REAPER."),
        ],
        "page2": "Werken Met REAPER Bronnen",
        "source_intro": "Gebruik het brontype dat past bij je edit in REAPER:",
        "top_icons_title": "Iconen rechtsboven",
        "top_icons": [
            "Taal: wissel de STEMwerk UI-taal.",
            "Tooltips: toon of verberg uitleg bij hover.",
            "Dag/nacht: wissel tussen lichte en donkere modus.",
            "FX: zet visuele effecten/art animatie aan of uit.",
        ],
        "sources": [
            ("Tijdselectie", "Gebruik een loop/tijdselectie als je alleen een regio wilt verwerken. Als er geen items of tracks geselecteerd zijn, kan STEMwerk die range gebruiken."),
            ("Media-items", "Selecteer een of meer media-items om complete items te verwerken. Items mogen op een track of over meerdere tracks staan."),
            ("Tracks", "Selecteer tracks als STEMwerk het materiaal op die tracks moet verwerken en stems als nieuwe tracks of folders moet terugplaatsen."),
            ("Takes / in-place", "Gebruik in-place output om stems als takes toe te voegen. Gebruik daarna Explode Takes om geselecteerde multi-take items naar tracks, losse items of volgorde-items te splitsen."),
        ],
        "page3": "Setup, Backends en Updates",
        "shortcuts_title": "Sneltoetsen",
        "main_shortcuts_title": "Hoofdvenster",
        "main_shortcuts": [
            ("Enter/Spatie", "Start separatie"),
            ("ESC", "Sluit of annuleer"),
            ("F1", "Open Help & Art Gallery"),
            ("1-6", "Stems aan/uit: Vocals, Drums, Bass, Other, Guitar, Piano"),
            ("K/I/A", "Karaoke/Instrumental, alle stems"),
            ("V/D/B/O/P/G", "Preset: Vocals, Drums, Bass, Other, Piano, Guitar"),
            ("F/Q/S", "Model: Fast, Quality, 6-Stem"),
            ("+/-", "Vergroot/verklein het hoofdvenster"),
        ],
        "help_shortcuts_title": "Help / Gallery",
        "help_shortcuts": [
            ("Enter", "Start vanuit Help of sluit voltooid-scherm"),
            ("Spatie", "Maak nieuwe art"),
            ("Links/Rechts", "Wissel tabs"),
            ("Muiswiel", "Zoom; sleep om te pannen, roteren of content te verplaatsen"),
            ("Dubbelklik", "Reset view"),
        ],
        "notes": [
            ("Windows", "Gebruik de installer voor normale setup. ReaPack installeert alleen scripts en is niet het aanbevolen eerste Windows setup-pad."),
            ("macOS / Linux", "Installeer met ReaPack en draai daarna STEMwerk-SETUP.lua voor eerste setup of reparatie. Een bestaande werkende venv hoeft meestal niet na elke update opnieuw."),
            ("CPU/GPU", "Auto kiest de beste gevonden backend. CPU is de veiligste fallback. CUDA, DirectML, ROCm en MPS hangen af van hardware, drivers en Python packages."),
            ("Eerste run", "Venv maken, packages installeren en het gekozen model downloaden kan enkele minuten duren. Latere runs zijn meestal sneller."),
            ("Problemen", "Meldt STEMwerk ontbrekende Python, FFmpeg, backend packages of een kapotte venv, draai dan STEMwerk-SETUP.lua opnieuw en bekijk de getoonde logs."),
        ],
    },
    "de": {
        "file": "README_de.pdf",
        "title": "STEMwerk fuer REAPER",
        "subtitle": "Lokale Stem-Trennung mit ausgewaehlten Tracks, Media-Items, Zeitauswahlen und Takes.",
        "page1": "Globaler Ablauf",
        "intro": [
            "STEMwerk trennt Vocals, Drums, Bass, Other und optional Guitar/Piano direkt in REAPER.",
            "Die Verarbeitung laeuft lokal. Der erste Lauf kann Setup, Backend-Pakete und Model-Downloads benoetigen.",
        ],
        "steps": [
            ("1. Installieren oder aktualisieren", "Unter Windows den Installer verwenden, unter macOS/Linux ReaPack. STEMwerk-SETUP.lua fuer Setup, Reparatur oder Dependency-Checks starten."),
            ("2. Quelle waehlen", "Media-Items, Tracks oder eine Zeitauswahl waehlen. Die aktive REAPER-Auswahl bestimmt, was STEMwerk verarbeitet."),
            ("3. Modell, Stems und Device waehlen", "Fast, Quality oder 6-Stem waehlen; vocals/drums/bass/other auswaehlen; Auto nutzen, ausser wenn CPU/GPU bewusst erzwungen werden soll."),
            ("4. Ausgabe waehlen", "Neue Stem-Tracks erstellen, in Ordner gruppieren oder Stems in-place als Takes auf dem Quell-Item schreiben."),
            ("5. Starten und pruefen", "STEMwerk klicken, das Fortschrittsfenster beobachten und danach Tracks, Items oder Takes in REAPER pruefen."),
        ],
        "page2": "Arbeiten Mit REAPER Quellen",
        "source_intro": "Nutze den Quelltyp, der zu deinem Edit in REAPER passt:",
        "top_icons_title": "Icons oben rechts",
        "top_icons": [
            "Sprache: STEMwerk UI-Sprache wechseln.",
            "Tooltips: Hover-Erklaerungen ein- oder ausblenden.",
            "Tag/Nacht: zwischen hellem und dunklem Modus wechseln.",
            "FX: visuelle Effekte/Art-Animation ein- oder ausschalten.",
        ],
        "sources": [
            ("Zeitauswahl", "Eine Loop-/Zeitauswahl nutzen, wenn nur ein Bereich verarbeitet werden soll. Sind keine Items oder Tracks ausgewaehlt, kann STEMwerk diesen Bereich verwenden."),
            ("Media-Items", "Ein oder mehrere Media-Items auswaehlen, um komplette Items zu verarbeiten. Items koennen auf einem Track oder auf mehreren Tracks liegen."),
            ("Tracks", "Tracks auswaehlen, wenn STEMwerk das Material auf diesen Tracks verarbeiten und Stems als neue Tracks oder Ordner zurueckgeben soll."),
            ("Takes / in-place", "In-place Ausgabe nutzen, um Stems als Takes hinzuzufuegen. Danach Explode Takes nutzen, um Multi-Take Items in Tracks, einzelne Items oder geordnete Items aufzuteilen."),
        ],
        "page3": "Setup, Backends und Updates",
        "shortcuts_title": "Tastaturkuerzel",
        "main_shortcuts_title": "Hauptfenster",
        "main_shortcuts": [
            ("Enter/Leertaste", "Trennung starten"),
            ("ESC", "Schliessen oder abbrechen"),
            ("F1", "Hilfe & Art Gallery oeffnen"),
            ("1-6", "Stems umschalten: Vocals, Drums, Bass, Other, Guitar, Piano"),
            ("K/I/A", "Karaoke/Instrumental, alle Stems"),
            ("V/D/B/O/P/G", "Preset: Vocals, Drums, Bass, Other, Piano, Guitar"),
            ("F/Q/S", "Modell: Fast, Quality, 6-Stem"),
            ("+/-", "Hauptfenster vergroessern/verkleinern"),
        ],
        "help_shortcuts_title": "Hilfe / Gallery",
        "help_shortcuts": [
            ("Enter", "Aus Hilfe starten oder Abschlussfenster schliessen"),
            ("Leertaste", "Neue Kunst erzeugen"),
            ("Links/Rechts", "Tabs wechseln"),
            ("Mausrad", "Zoomen; ziehen zum Schwenken, Rotieren oder Bewegen"),
            ("Doppelklick", "Ansicht zuruecksetzen"),
        ],
        "notes": [
            ("Windows", "Fuer normales Setup den Installer verwenden. ReaPack installiert nur Scripts und ist nicht der empfohlene erste Windows-Setup-Weg."),
            ("macOS / Linux", "Mit ReaPack installieren und danach STEMwerk-SETUP.lua fuer Erst-Setup oder Reparatur starten. Eine funktionierende venv muss meist nicht nach jedem Update neu eingerichtet werden."),
            ("CPU/GPU", "Auto waehlt das beste erkannte Backend. CPU ist der sicherste Fallback. CUDA, DirectML, ROCm und MPS haengen von Hardware, Treibern und Python-Paketen ab."),
            ("Erster Lauf", "venv erstellen, Pakete installieren und das gewaehlte Modell laden kann mehrere Minuten dauern. Spaetere Laeufe sind normalerweise schneller."),
            ("Fehlersuche", "Wenn Python, FFmpeg, Backend-Pakete oder eine defekte venv gemeldet werden, STEMwerk-SETUP.lua erneut starten und die angezeigten Logs pruefen."),
        ],
    },
}


def prepare_assets():
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    extract_first_frame(ROOT / "docs/assets/STEMwerk.gif", ASSET_DIR / "stemwerk_logo.png")
    extract_first_frame(ROOT / "docs/assets/stemwerk_fullscreen.gif", ASSET_DIR / "stemwerk_fullscreen.png")


def extract_first_frame(src, dst):
    im = Image.open(src)
    im.seek(0)
    im.convert("RGBA").save(dst)


def new_page():
    return Image.new("RGB", (PAGE_W, PAGE_H), COL["bg"])


def rounded(draw, xy, radius=18, fill=COL["panel"], outline=COL["line"], width=2):
    draw.rounded_rectangle(xy, radius=radius, fill=fill, outline=outline, width=width)


def text(draw, xy, s, fnt, fill=COL["ink"], max_width=None, line_gap=7):
    x, y = xy
    if not max_width:
        draw.text((x, y), s, font=fnt, fill=fill)
        return y + draw.textbbox((x, y), s, font=fnt)[3] - draw.textbbox((x, y), s, font=fnt)[1]
    words = s.split()
    lines, cur = [], ""
    for word in words:
        trial = (cur + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= max_width:
            cur = trial
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    for line in lines:
        draw.text((x, y), line, font=fnt, fill=fill)
        y += fnt.size + line_gap
    return y


def paste_image(page, path, box, radius=16):
    img = Image.open(path).convert("RGB")
    x, y, w, h = box
    img.thumbnail((w, h), Image.LANCZOS)
    panel = Image.new("RGB", (w, h), COL["panel"])
    px = (w - img.width) // 2
    py = (h - img.height) // 2
    panel.paste(img, (px, py))
    mask = Image.new("L", (w, h), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, w, h), radius=radius, fill=255)
    page.paste(panel, (x, y), mask)
    d = ImageDraw.Draw(page)
    d.rounded_rectangle((x, y, x + w, y + h), radius=radius, outline=COL["line"], width=2)


def icon_row(page, x, y):
    files = [
        "stemwerk_main.png",
        "stemwerk_vocals_only.png",
        "stemwerk_drums_only.png",
        "stemwerk_bass_only.png",
        "stemwerk_all_stems.png",
        "stemwerk_karaoke.png",
        "stemwerk_explode_takes.png",
        "stemwerk_setup.png",
    ]
    size = 58
    gap = 18
    for i, name in enumerate(files):
        p = ROOT / "scripts/reaper/assets/toolbar_icons" / name
        im = Image.open(p).convert("RGBA")
        im.thumbnail((size, size), Image.LANCZOS)
        bx = x + i * (size + gap)
        ImageDraw.Draw(page).rounded_rectangle((bx - 5, y - 5, bx + size + 5, y + size + 5), radius=12, fill=(244, 247, 250), outline=COL["line"])
        page.paste(im, (bx + (size - im.width) // 2, y + (size - im.height) // 2), im)


def header(page, d, data, page_title):
    paste_image(page, ASSET_DIR / "stemwerk_logo.png", (MARGIN, 54, 268, 82), radius=10)
    d.text((MARGIN + 300, 58), data["title"], font=F["title"], fill=COL["ink"])
    d.text((MARGIN + 302, 122), page_title, font=F["subtitle"], fill=COL["muted"])
    d.line((MARGIN, 174, PAGE_W - MARGIN, 174), fill=COL["line"], width=2)


def draw_bullet_block(d, x, y, items, width, color_cycle=True):
    for i, (title, body) in enumerate(items):
        color = [COL["accent"], COL["green"], COL["accent2"], COL["orange"], (120, 92, 210)][i % 5]
        d.ellipse((x, y + 7, x + 18, y + 25), fill=color)
        d.text((x + 34, y), title, font=F["h2"], fill=COL["ink"])
        y = text(d, (x + 34, y + 34), body, F["body"], COL["muted"], max_width=width - 34)
        y += 22
    return y


def page_one(data):
    page = new_page()
    d = ImageDraw.Draw(page)
    header(page, d, data, data["page1"])
    y = 212
    for line in data["intro"]:
        y = text(d, (MARGIN, y), line, F["body"], COL["muted"], max_width=CONTENT_W)
        y += 8
    paste_image(page, ASSET_DIR / "stemwerk_fullscreen.png", (MARGIN, 325, CONTENT_W, 610), radius=20)
    y = 982
    d.text((MARGIN, y), data["page1"], font=F["h1"], fill=COL["ink"])
    y += 50
    draw_bullet_block(d, MARGIN, y, data["steps"], CONTENT_W)
    footer(d, 1)
    return page


def source_card(d, x, y, w, h, title, body, color):
    rounded(d, (x, y, x + w, y + h), radius=18)
    d.rounded_rectangle((x, y, x + 12, y + h), radius=6, fill=color)
    d.text((x + 30, y + 24), title, font=F["h2"], fill=COL["ink"])
    text(d, (x + 30, y + 64), body, F["body"], COL["muted"], max_width=w - 56)


def page_two(data):
    page = new_page()
    d = ImageDraw.Draw(page)
    header(page, d, data, data["page2"])
    y = 224
    y = text(d, (MARGIN, y), data["source_intro"], F["body"], COL["muted"], max_width=CONTENT_W)
    y += 34
    card_w = (CONTENT_W - 30) // 2
    card_h = 275
    colors = [COL["accent"], COL["green"], COL["orange"], COL["accent2"]]
    for i, (title, body) in enumerate(data["sources"]):
        cx = MARGIN + (i % 2) * (card_w + 30)
        cy = y + (i // 2) * (card_h + 30)
        source_card(d, cx, cy, card_w, card_h, title, body, colors[i])
    y += 2 * (card_h + 30) + 6
    d.text((MARGIN, y), "Toolbar / Actions", font=F["h1"], fill=COL["ink"])
    y += 60
    icon_row(page, MARGIN + 8, y)
    y += 88
    rounded(d, (MARGIN, y, PAGE_W - MARGIN, y + 130), radius=16, fill=(244, 247, 250))
    d.text((MARGIN + 24, y + 18), data["top_icons_title"], font=F["h2"], fill=COL["ink"])
    yy = y + 54
    for line in data["top_icons"]:
        yy = text(d, (MARGIN + 24, yy), line, F["tiny"], COL["muted"], max_width=CONTENT_W - 48, line_gap=2)
        yy += 1
    y += 150
    paste_image(page, ASSET_DIR / "stemwerk_fullscreen.png", (MARGIN, y, CONTENT_W, 300), radius=20)
    footer(d, 2)
    return page


def page_three(data):
    page = new_page()
    d = ImageDraw.Draw(page)
    header(page, d, data, data["page3"])
    y = 220
    y = draw_bullet_block(d, MARGIN, y, data["notes"], CONTENT_W)
    y += 18
    rounded(d, (MARGIN, y, PAGE_W - MARGIN, y + 455), radius=20, fill=(244, 247, 250))
    d.text((MARGIN + 34, y + 30), data["shortcuts_title"], font=F["h1"], fill=COL["ink"])
    col_w = (CONTENT_W - 88) // 2
    left_x = MARGIN + 34
    right_x = left_x + col_w + 42
    yy = y + 88
    draw_shortcut_group(d, left_x, yy, col_w, data["main_shortcuts_title"], data["main_shortcuts"])
    draw_shortcut_group(d, right_x, yy, col_w, data["help_shortcuts_title"], data["help_shortcuts"])
    y = 1330
    rounded(d, (MARGIN, y, PAGE_W - MARGIN, y + 230), radius=20, fill=(244, 247, 250))
    d.text((MARGIN + 34, y + 32), "Install location", font=F["h1"], fill=COL["ink"])
    install = [
        "Windows: %APPDATA%\\REAPER\\Scripts\\STEMwerk-reaper\\",
        "Linux: ~/.config/REAPER/Scripts/STEMwerk-reaper/",
        "macOS: ~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper/",
    ]
    yy = y + 88
    for line in install:
        yy = text(d, (MARGIN + 34, yy), line, F["body"], COL["muted"], max_width=CONTENT_W - 68)
        yy += 8
    footer(d, 3)
    return page


def draw_shortcut_group(d, x, y, w, title, rows):
    d.text((x, y), title, font=F["h2"], fill=COL["ink"])
    y += 42
    key_w = 132
    for key, body in rows:
        d.rounded_rectangle((x, y, x + key_w, y + 31), radius=8, fill=(255, 255, 255), outline=COL["line"], width=1)
        d.text((x + 11, y + 6), key, font=F["tiny"], fill=COL["accent"])
        text(d, (x + key_w + 14, y + 2), body, F["tiny"], COL["muted"], max_width=w - key_w - 14, line_gap=2)
        y += 35


def footer(d, n):
    d.line((MARGIN, PAGE_H - 70, PAGE_W - MARGIN, PAGE_H - 70), fill=COL["line"], width=2)
    d.text((MARGIN, PAGE_H - 48), "STEMwerk-reaper", font=F["tiny"], fill=COL["muted"])
    d.text((PAGE_W - MARGIN - 36, PAGE_H - 48), str(n), font=F["tiny"], fill=COL["muted"])


def build_pdf(lang, data):
    pages = [page_one(data), page_two(data), page_three(data)]
    out = OUT_DIR / data["file"]
    pages[0].save(out, "PDF", resolution=150, save_all=True, append_images=pages[1:])
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    prepare_assets()
    for lang, data in DATA.items():
        out = build_pdf(lang, data)
        print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
