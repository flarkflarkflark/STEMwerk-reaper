#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "scripts" / "reaper" / "assets" / "toolbar_icons"
MASTER_ROOT = ASSET_ROOT
SINGLE_ROOT = ASSET_ROOT / "single"
STRIP_1X_ROOT = ASSET_ROOT / "strips_90x30"
STRIP_150_ROOT = ASSET_ROOT / "strips_135x45"
STRIP_2X_ROOT = ASSET_ROOT / "strips_180x60"


ICON_NAMES = (
    "stemwerk_main",
    "stemwerk_setup",
    "stemwerk_karaoke",
    "stemwerk_vocals_only",
    "stemwerk_drums_only",
    "stemwerk_bass_only",
    "stemwerk_all_stems",
    "stemwerk_explode_takes",
)


@dataclass(frozen=True)
class StripSpec:
    single_size: int
    cell_size: int
    output_suffix: str
    output_dir: Path


SPECS = (
    StripSpec(single_size=30, cell_size=30, output_suffix="90x30", output_dir=STRIP_1X_ROOT),
    StripSpec(single_size=45, cell_size=45, output_suffix="135x45", output_dir=STRIP_150_ROOT),
    StripSpec(single_size=60, cell_size=60, output_suffix="180x60", output_dir=STRIP_2X_ROOT),
)

SINGLE_SIZES = (24, 30, 36, 45, 48, 60, 64)

STEM_COLORS = {
    "S": (255, 94, 82),   # coral/red
    "T": (46, 201, 255),  # cyan/blue
    "E": (171, 103, 255), # purple
    "M": (83, 244, 126),  # green
}

BG_TOP = (16, 34, 66)
BG_BOTTOM = (8, 20, 40)
BORDER_SOFT = (154, 178, 214, 180)
ICON_LIGHT = (242, 246, 252, 255)
ICON_DIM = (210, 221, 238, 255)


def fit_to_cell(icon: Image.Image, cell_size: int) -> Image.Image:
    canvas = Image.new("RGBA", (cell_size, cell_size), (0, 0, 0, 0))
    x = (cell_size - icon.width) // 2
    y = (cell_size - icon.height) // 2
    canvas.alpha_composite(icon, dest=(x, y))
    return canvas


def apply_rgb_gain(icon: Image.Image, gain: float) -> Image.Image:
    red, green, blue, alpha = icon.split()

    def scale(channel: Image.Image) -> Image.Image:
        return channel.point(lambda value: min(255, max(0, int(round(value * gain)))))

    return Image.merge("RGBA", (scale(red), scale(green), scale(blue), alpha))


def make_hover(icon: Image.Image) -> Image.Image:
    return apply_rgb_gain(icon, 1.14)


def make_active(icon: Image.Image) -> Image.Image:
    return apply_rgb_gain(icon, 0.84)


def build_strip(icon: Image.Image) -> Image.Image:
    states = (icon, make_hover(icon), make_active(icon))
    strip = Image.new("RGBA", (icon.width * 3, icon.height), (0, 0, 0, 0))
    for index, state in enumerate(states):
        strip.alpha_composite(state, dest=(index * icon.width, 0))
    return strip


def load_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    names = (
        "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf",
        "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
    )
    for name in names:
        try:
            return ImageFont.truetype(name, size=size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_base(size: int = 256) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # vertical gradient background
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(BG_TOP[0] * (1 - t) + BG_BOTTOM[0] * t)
        g = int(BG_TOP[1] * (1 - t) + BG_BOTTOM[1] * t)
        b = int(BG_TOP[2] * (1 - t) + BG_BOTTOM[2] * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # subtle blobs
    draw.ellipse((20, 18, 130, 128), fill=(110, 148, 220, 50))
    draw.ellipse((132, 132, 240, 240), fill=(95, 137, 214, 42))

    # rounded mask and border
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    pad = 6
    rad = 28
    mdraw.rounded_rectangle((pad, pad, size - pad - 1, size - pad - 1), radius=rad, fill=255)

    clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clipped.paste(canvas, (0, 0), mask)

    # border glow
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    inset = 8
    rect = (inset, inset, size - inset - 1, size - inset - 1)
    seg_colors = [STEM_COLORS["S"], STEM_COLORS["T"], STEM_COLORS["E"], STEM_COLORS["M"]]
    # top, right, bottom, left simplified multicolor strokes
    gdraw.arc(rect, start=220, end=320, fill=seg_colors[0] + (220,), width=4)
    gdraw.arc(rect, start=320, end=40, fill=seg_colors[1] + (220,), width=4)
    gdraw.arc(rect, start=40, end=140, fill=seg_colors[2] + (220,), width=4)
    gdraw.arc(rect, start=140, end=220, fill=seg_colors[3] + (220,), width=4)
    glow = glow.filter(ImageFilter.GaussianBlur(2.2))
    clipped.alpha_composite(glow)

    fdraw = ImageDraw.Draw(clipped)
    fdraw.rounded_rectangle((pad, pad, size - pad - 1, size - pad - 1), radius=rad, outline=BORDER_SOFT, width=2)

    return clipped, fdraw


def draw_stem_header(draw: ImageDraw.ImageDraw, size: int, y: int, scale: float = 1.0) -> None:
    font = load_font(int(42 * scale), bold=True)
    letters = "STEM"
    spacing = int(8 * scale)
    widths = [int(draw.textlength(ch, font=font)) for ch in letters]
    total = sum(widths) + spacing * (len(letters) - 1)
    x = (size - total) // 2
    for ch, w in zip(letters, widths):
        c = STEM_COLORS[ch]
        draw.text((x, y), ch, font=font, fill=c + (255,))
        x += w + spacing


def draw_wave(draw: ImageDraw.ImageDraw, x0: int, y: int, w: int, color: tuple[int, int, int], amp: int = 10) -> None:
    pts = []
    for i in range(0, w + 1, 6):
        t = i / max(1, w)
        a = (1 - abs(0.5 - t) * 1.5)
        dy = int(((-1) ** (i // 6)) * amp * a)
        pts.append((x0 + i, y + dy))
    if len(pts) >= 2:
        draw.line(pts, fill=color + (245,), width=4, joint="curve")


def glyph_main(draw: ImageDraw.ImageDraw, size: int) -> None:
    draw_stem_header(draw, size, y=96, scale=1.0)


def glyph_setup(draw: ImageDraw.ImageDraw, size: int) -> None:
    cx, cy = size // 2, 148
    draw.ellipse((cx - 46, cy - 46, cx + 46, cy + 46), outline=ICON_LIGHT, width=13)
    for i in range(8):
        import math
        a = i * (math.pi / 4)
        x1, y1 = cx + int(50 * math.cos(a)), cy + int(50 * math.sin(a))
        x2, y2 = cx + int(68 * math.cos(a)), cy + int(68 * math.sin(a))
        draw.line((x1, y1, x2, y2), fill=ICON_LIGHT, width=11)
    draw.ellipse((cx - 16, cy - 16, cx + 16, cy + 16), fill=BG_BOTTOM + (255,))


def glyph_karaoke(draw: ImageDraw.ImageDraw, size: int) -> None:
    cx, cy = size // 2, 150
    draw.rounded_rectangle((cx - 22, cy - 56, cx + 22, cy + 18), radius=20, outline=ICON_LIGHT, width=9)
    draw.line((cx, cy + 20, cx, cy + 48), fill=ICON_LIGHT, width=9)
    draw.arc((cx - 30, cy + 36, cx + 30, cy + 72), start=200, end=-20, fill=ICON_LIGHT, width=8)
    draw.line((cx - 62, cy - 58, cx + 60, cy + 62), fill=(255, 76, 76, 255), width=12)


def glyph_vocals(draw: ImageDraw.ImageDraw, size: int) -> None:
    cx, cy = size // 2, 148
    draw.rounded_rectangle((cx - 20, cy - 54, cx + 20, cy + 16), radius=18, fill=ICON_LIGHT)
    draw.line((cx, cy + 18, cx, cy + 48), fill=ICON_LIGHT, width=8)
    draw.arc((cx - 28, cy + 34, cx + 28, cy + 68), start=200, end=-20, fill=ICON_LIGHT, width=7)
    draw_wave(draw, 30, cy - 4, 60, STEM_COLORS["S"], amp=9)
    draw_wave(draw, size - 90, cy - 4, 60, STEM_COLORS["S"], amp=9)


def glyph_drums(draw: ImageDraw.ImageDraw, size: int) -> None:
    cx, cy = size // 2, 154
    draw.ellipse((cx - 40, cy - 24, cx + 40, cy + 24), outline=ICON_LIGHT, width=8)
    draw.line((cx - 40, cy, cx + 40, cy), fill=ICON_LIGHT, width=5)
    draw.line((cx - 26, cy - 38, cx + 28, cy + 8), fill=ICON_LIGHT, width=7)
    draw.line((cx + 24, cy - 40, cx - 30, cy + 8), fill=ICON_LIGHT, width=7)
    draw_wave(draw, 22, cy - 8, 52, STEM_COLORS["T"], amp=8)
    draw_wave(draw, size - 74, cy - 8, 52, STEM_COLORS["T"], amp=8)


def glyph_bass(draw: ImageDraw.ImageDraw, size: int) -> None:
    cx, cy = size // 2, 150
    # stylized bass neck/body
    draw.rounded_rectangle((cx - 16, cy - 50, cx + 8, cy + 40), radius=8, fill=ICON_LIGHT)
    draw.ellipse((cx - 52, cy - 2, cx - 10, cy + 36), fill=ICON_LIGHT)
    draw.ellipse((cx - 12, cy - 10, cx + 20, cy + 20), fill=BG_BOTTOM + (255,))
    draw.line((cx - 4, cy - 58, cx + 24, cy - 84), fill=ICON_LIGHT, width=8)
    draw.ellipse((cx + 20, cy - 88, cx + 34, cy - 74), fill=ICON_LIGHT)
    draw_wave(draw, 18, cy + 10, 64, STEM_COLORS["M"], amp=8)
    draw_wave(draw, size - 82, cy + 10, 64, STEM_COLORS["M"], amp=8)


def glyph_all_stems(draw: ImageDraw.ImageDraw, size: int) -> None:
    lanes = [STEM_COLORS["S"], STEM_COLORS["T"], STEM_COLORS["E"], STEM_COLORS["M"]]
    y = 106
    for c in lanes:
        draw.rounded_rectangle((34, y, size - 34, y + 24), radius=8, outline=ICON_DIM, width=2, fill=(10, 26, 52, 180))
        draw_wave(draw, 52, y + 12, size - 104, c, amp=8)
        y += 30


def glyph_explode(draw: ImageDraw.ImageDraw, size: int) -> None:
    lanes = [STEM_COLORS["S"], STEM_COLORS["T"], STEM_COLORS["E"], STEM_COLORS["M"]]
    ys = [114, 144, 174, 204]
    for y in ys:
        draw.rounded_rectangle((24, y - 10, 94, y + 10), radius=7, fill=(232, 236, 244, 255))
    for c, y in zip(lanes, ys):
        draw.rounded_rectangle((162, y - 12, 232, y + 12), radius=8, fill=(c[0], c[1], c[2], 255))
        draw_wave(draw, 170, y, 54, c, amp=5)
    # branching arrows
    draw.line((96, 160, 136, 160), fill=ICON_LIGHT, width=5)
    for y in ys:
        draw.line((136, 160, 160, y), fill=ICON_LIGHT, width=5)
        draw.polygon([(160, y), (152, y - 4), (152, y + 4)], fill=ICON_LIGHT)


GLYPHS: dict[str, Callable[[ImageDraw.ImageDraw, int], None]] = {
    "stemwerk_main": glyph_main,
    "stemwerk_setup": glyph_setup,
    "stemwerk_karaoke": glyph_karaoke,
    "stemwerk_vocals_only": glyph_vocals,
    "stemwerk_drums_only": glyph_drums,
    "stemwerk_bass_only": glyph_bass,
    "stemwerk_all_stems": glyph_all_stems,
    "stemwerk_explode_takes": glyph_explode,
}


def generate_master_icons() -> None:
    for icon_name in ICON_NAMES:
        canvas, draw = make_base(256)
        # thin STEM color ticks for family identity
        ticks = [STEM_COLORS[k] for k in "STEM"]
        tx = 30
        for c in ticks:
            draw.rounded_rectangle((tx, 26, tx + 40, 34), radius=4, fill=c + (255,))
            tx += 48
        glyph_fn = GLYPHS[icon_name]
        glyph_fn(draw, 256)
        target = MASTER_ROOT / f"{icon_name}.png"
        canvas.save(target)
        print(f"wrote {target.relative_to(ROOT)} 256x256")


def load_master(icon_name: str) -> Image.Image:
    path = MASTER_ROOT / f"{icon_name}.png"
    if not path.exists():
        raise FileNotFoundError(f"Missing master icon: {path}")
    with Image.open(path) as image:
        return image.convert("RGBA")


def render_single(master: Image.Image, size: int) -> Image.Image:
    return master.resize((size, size), Image.Resampling.LANCZOS)


def generate_singles() -> None:
    SINGLE_ROOT.mkdir(parents=True, exist_ok=True)
    for icon_name in ICON_NAMES:
        master = load_master(icon_name)
        for size in SINGLE_SIZES:
            single = render_single(master, size)
            target = SINGLE_ROOT / f"{icon_name}_{size}.png"
            single.save(target)
            print(f"wrote {target.relative_to(ROOT)} {single.width}x{single.height}")


def load_single(icon_name: str, single_size: int) -> Image.Image:
    path = SINGLE_ROOT / f"{icon_name}_{single_size}.png"
    if not path.exists():
        raise FileNotFoundError(f"Missing single icon: {path}")
    with Image.open(path) as image:
        return image.convert("RGBA")


def generate() -> None:
    generate_master_icons()
    generate_singles()
    for spec in SPECS:
        spec.output_dir.mkdir(parents=True, exist_ok=True)
        for icon_name in ICON_NAMES:
            source = load_single(icon_name, spec.single_size)
            cell = fit_to_cell(source, spec.cell_size)
            strip = build_strip(cell)
            target = spec.output_dir / f"{icon_name}_{spec.output_suffix}.png"
            strip.save(target)
            print(f"wrote {target.relative_to(ROOT)} {strip.width}x{strip.height}")


if __name__ == "__main__":
    generate()
