#!/usr/bin/env python3
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "scripts/reaper/assets/toolbar_icons"
SINGLE = ASSETS / "single"
STRIP_1X = ASSETS / "strips_90x30"
STRIP_2X = ASSETS / "strips_180x60"
ICON_NAMES = ("stemwerk_direct_kit", "stemwerk_kit_split")
SINGLE_SIZES = (24, 30, 36, 48, 64)


def line(draw, points, fill, width):
    draw.line(points, fill=fill, width=width, joint="curve")


def base_canvas():
    base = Image.open(ASSETS / "stemwerk_main.png").convert("RGBA")
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle((14, 14, 242, 242), radius=36, fill=(12, 21, 27, 255))
    draw.rounded_rectangle((20, 20, 236, 236), radius=31, outline=(36, 56, 66, 255), width=3)
    return base


def draw_drum(draw, box):
    x0, y0, x1, y1 = box
    cyan = (36, 222, 244, 255)
    pale = (220, 248, 252, 255)
    draw.ellipse((x0, y0, x1, y0 + 32), fill=(22, 78, 91, 255), outline=pale, width=5)
    draw.rectangle((x0, y0 + 15, x1, y1 - 15), fill=(11, 89, 108, 255), outline=cyan, width=5)
    draw.ellipse((x0, y1 - 32, x1, y1), fill=(9, 57, 69, 255), outline=pale, width=5)
    draw.ellipse((x0, y0, x1, y0 + 32), outline=cyan, width=4)
    for x in (x0 + 14, x1 - 14):
        line(draw, ((x, y0 + 22), (x, y1 - 20)), pale, 4)


def draw_outputs(draw, origin, columns):
    colors = ((255, 92, 96, 255), (36, 222, 244, 255), (176, 104, 255, 255),
              (126, 236, 74, 255), (255, 188, 72, 255), (88, 154, 255, 255))
    nodes = []
    for col, x in enumerate(columns):
        for row in range(3):
            y = 72 + row * 55 + (col * 10)
            nodes.append((x, y))
    for index, (x, y) in enumerate(nodes):
        line(draw, (origin, (origin[0] + 18, y), (x - 12, y)), (214, 231, 235, 230), 4)
        draw.rounded_rectangle((x - 9, y - 14, x + 9, y + 14), radius=5,
                               fill=colors[index], outline=(238, 250, 252, 255), width=2)


def direct_kit():
    image = base_canvas()
    draw = ImageDraw.Draw(image)
    draw_drum(draw, (42, 76, 128, 179))
    origin = (132, 127)
    line(draw, ((117, 127), origin), (238, 250, 252, 255), 6)
    draw_outputs(draw, origin, (170, 211))
    return image


def kit_split():
    image = base_canvas()
    draw = ImageDraw.Draw(image)
    cyan = (36, 222, 244, 255)
    waveform = ((34, 128), (43, 128), (49, 101), (57, 154), (66, 83),
                (76, 169), (85, 109), (94, 142), (103, 128))
    line(draw, waveform, (235, 244, 247, 255), 6)
    line(draw, ((104, 128), (120, 128)), cyan, 6)
    draw.polygon(((120, 128), (108, 120), (108, 136)), fill=cyan)
    draw_drum(draw, (120, 89, 171, 166))
    origin = (176, 128)
    line(draw, ((169, 128), origin), (238, 250, 252, 255), 5)
    draw_outputs(draw, origin, (207, 230))
    return image


def rgb_gain(image, gain):
    red, green, blue, alpha = image.split()
    scale = lambda channel: channel.point(lambda value: min(255, round(value * gain)))
    return Image.merge("RGBA", (scale(red), scale(green), scale(blue), alpha))


def strip(single):
    result = Image.new("RGBA", (single.width * 3, single.height))
    for index, state in enumerate((single, rgb_gain(single, 1.14), rgb_gain(single, 0.84))):
        result.alpha_composite(state, (index * single.width, 0))
    return result


def generate():
    masters = {"stemwerk_direct_kit": direct_kit(), "stemwerk_kit_split": kit_split()}
    for directory in (SINGLE, STRIP_1X, STRIP_2X):
        directory.mkdir(parents=True, exist_ok=True)
    for name in ICON_NAMES:
        master = masters[name]
        master.save(ASSETS / f"{name}.png")
        for size in SINGLE_SIZES:
            master.resize((size, size), Image.Resampling.LANCZOS).save(SINGLE / f"{name}_{size}.png")
        strip(master.resize((30, 30), Image.Resampling.LANCZOS)).save(STRIP_1X / f"{name}_90x30.png")
        strip(master.resize((60, 60), Image.Resampling.LANCZOS)).save(STRIP_2X / f"{name}_180x60.png")


if __name__ == "__main__":
    generate()
