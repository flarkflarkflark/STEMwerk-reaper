#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image


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
