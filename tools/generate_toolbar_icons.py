#!/usr/bin/env python3
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "scripts" / "reaper" / "assets" / "toolbar_icons"
SINGLE_ROOT = ASSET_ROOT / "single"
STRIP_1X_ROOT = ASSET_ROOT / "strips_90x30"
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
    source_size: int
    cell_size: int
    output_suffix: str
    output_dir: Path


SPECS = (
    StripSpec(source_size=24, cell_size=30, output_suffix="90x30", output_dir=STRIP_1X_ROOT),
    StripSpec(source_size=48, cell_size=60, output_suffix="180x60", output_dir=STRIP_2X_ROOT),
)


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


def load_source(icon_name: str, source_size: int) -> Image.Image:
    path = SINGLE_ROOT / f"{icon_name}_{source_size}.png"
    if not path.exists():
        raise FileNotFoundError(f"Missing source icon: {path}")
    with Image.open(path) as image:
        return image.convert("RGBA")


def generate() -> None:
    for spec in SPECS:
        spec.output_dir.mkdir(parents=True, exist_ok=True)
        for icon_name in ICON_NAMES:
            source = load_source(icon_name, spec.source_size)
            cell = fit_to_cell(source, spec.cell_size)
            strip = build_strip(cell)
            target = spec.output_dir / f"{icon_name}_{spec.output_suffix}.png"
            strip.save(target)
            print(f"wrote {target.relative_to(ROOT)} {strip.width}x{strip.height}")


if __name__ == "__main__":
    generate()
