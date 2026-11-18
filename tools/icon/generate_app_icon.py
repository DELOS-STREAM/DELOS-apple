#!/usr/bin/env python3
"""Generates the app icon asset catalog (App/Shared/Assets.xcassets) from the vector mark of DELOS for Android.

Run: python3 tools/icon/generate_app_icon.py   (needs Pillow; no network)

The master is the Android adaptive icon: res/drawable/ic_launcher_foreground.xml and ic_launcher_monochrome.xml
(108dp viewport) over the colour ic_launcher_background. The numbers below are copied from those files; every image
is drawn from them at its own pixel size, nothing is scaled from a raster. An Android launcher shows the centred
72dp of the 108dp layers, so 72dp maps to the icon's side here (to its height on tvOS and on the Top Shelf), which
keeps the mark as large in the icon as on Android.

- iOS and iPadOS: 1024 px, opaque and square (the system masks it). Dark is the same art (the icon is dark already);
  tinted is Android's monochrome layer in white on black, which the system colours.
- macOS: Apple's template: an 824 px continuous-corner square (radius 185.4) centred in 1024 px with its drop shadow
  (28 px blur, 12 px down, 50 % black), drawn at each of the ten sizes.
- tvOS: layered icons (Back: the background colour, Front: the mark on transparency) and the Top Shelf images.
"""
from pathlib import Path
import json

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "App/Shared/Assets.xcassets"
TV = "App Icon & Top Shelf Image.brandassets"

# ic_launcher_foreground.xml, ic_launcher_monochrome.xml, ic_launcher_background.xml
VIEWPORT, VISIBLE = 108.0, 72.0
CX, CY = 54.0, 54.0
RADIUS, STROKE = 18.722, 3.036
MOON_X, MOON_Y = CX + 18.722, CY - 12.65
MOON_RADIUS, HALO_RADIUS, HALO_ALPHA = 5.566, 9.108, 0.35
BACKGROUND = (0x0B, 0x0F, 0x19)
ACCENT = (0xFA, 0xBD, 0x42)
MOON = (0x4C, 0xD0, 0xF0)
WHITE = (255, 255, 255)

SUPERSAMPLE = 4
INFO = {"author": "xcode", "version": 1}


def downsample(image, size):
    """Lanczos on premultiplied alpha, so transparent pixels do not darken the edges."""
    return image.convert("RGBa").resize(size, Image.Resampling.LANCZOS).convert("RGBA")


def mark(side, monochrome=False):
    """The mark on transparency: the centred 72dp of the Android layers in a square of `side` pixels."""
    big = side * SUPERSAMPLE
    k = big / VISIBLE
    origin = (VIEWPORT - VISIBLE) / 2
    image = Image.new("RGBA", (big, big))

    def box(x, y, radius):
        return ((x - origin - radius) * k, (y - origin - radius) * k, (x - origin + radius) * k, (y - origin + radius) * k)

    def disk(x, y, radius, fill):
        layer = Image.new("RGBA", image.size)
        ImageDraw.Draw(layer).ellipse(box(x, y, radius), fill=fill)
        image.alpha_composite(layer)

    draw = ImageDraw.Draw(image)
    draw.ellipse(box(CX, CY, RADIUS + STROKE / 2), fill=(WHITE if monochrome else ACCENT) + (255,))
    draw.ellipse(box(CX, CY, RADIUS - STROKE / 2), fill=(0, 0, 0, 0))
    if not monochrome:
        disk(MOON_X, MOON_Y, HALO_RADIUS, MOON + (round(HALO_ALPHA * 255),))
    disk(MOON_X, MOON_Y, MOON_RADIUS, (WHITE if monochrome else MOON) + (255,))
    return downsample(image, (side, side))


def on_background(width, height, background=BACKGROUND, monochrome=False):
    """The mark centred on an opaque canvas, 72dp to the canvas height."""
    image = Image.new("RGBA", (width, height), background + (255,))
    image.alpha_composite(mark(height, monochrome), ((width - height) // 2, 0))
    return image.convert("RGB")


def front(width, height):
    image = Image.new("RGBA", (width, height))
    image.alpha_composite(mark(height), ((width - height) // 2, 0))
    return image


def back(width, height):
    return Image.new("RGB", (width, height), BACKGROUND)


def cubic(p0, p1, p2, p3, steps=64):
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        yield tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d for a, b, c, d in zip(p0, p1, p2, p3))


def continuous_square(left, top, side, radius):
    """Outline of a square with Apple's continuous corners (the curve of UIBezierPath's rounded rectangle)."""
    r = radius
    # The top right corner in the square's own coordinates, from the top edge to the right edge
    corner = [(side - 1.528665 * r, 0.0)]
    corner += cubic(corner[-1], (side - 1.08849 * r, 0), (side - 0.868407 * r, 0), (side - 0.631494 * r, 0.074911 * r))
    corner += cubic(corner[-1], (side - 0.372824 * r, 0.16906 * r), (side - 0.16906 * r, 0.372824 * r),
                    (side - 0.074911 * r, 0.631494 * r))
    corner += cubic(corner[-1], (side, 0.868407 * r), (side, 1.08849 * r), (side, 1.528665 * r))
    points = []
    for turn in range(4):  # each quarter turn sends (x, y) to (side - y, x)
        for x, y in corner:
            for _ in range(turn):
                x, y = side - y, x
            points.append((left + x, top + y))
    return points


def mac(size):
    big = size * SUPERSAMPLE
    k = big / 1024
    shape = Image.new("L", (big, big))
    ImageDraw.Draw(shape).polygon(continuous_square(100 * k, 100 * k, 824 * k, 185.4 * k), fill=255)

    image = Image.new("RGBA", (big, big))
    shadow = Image.new("L", (big, big))
    shadow.paste(shape, (0, round(12 * k)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * k)).point(lambda value: value // 2)
    image.paste((0, 0, 0, 255), mask=shadow)
    image.paste(BACKGROUND + (255,), mask=shape)
    image = downsample(image, (size, size))

    # The mark is drawn at its final pixel size: the shape's side at this icon size
    side = round(824 * size / 1024)
    offset = (size - side) // 2
    image.alpha_composite(mark(side), (offset, offset))
    return image


def save(folder, name, image):
    folder.mkdir(parents=True, exist_ok=True)
    image.save(folder / name, optimize=True)


def contents(folder, value):
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "Contents.json").write_text(json.dumps({**value, "info": INFO}, indent=2) + "\n")


def app_icon():
    folder = CATALOG / "AppIcon.appiconset"
    images = []
    for name, appearance, image in (
        ("ios-1024.png", None, on_background(1024, 1024)),
        ("ios-1024-dark.png", "dark", on_background(1024, 1024)),
        ("ios-1024-tinted.png", "tinted", on_background(1024, 1024, (0, 0, 0), monochrome=True).convert("L")),
    ):
        save(folder, name, image)
        entry = {"filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"mac-{points}@{scale}x.png"
            save(folder, name, mac(points * scale))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    contents(folder, {"images": images})


def image_set(folder, name, width, height, scales, draw):
    images = []
    for scale in scales:
        file = f"{name}@{scale}x.png"
        save(folder, file, draw(width * scale, height * scale))
        images.append({"filename": file, "idiom": "tv", "scale": f"{scale}x"})
    contents(folder, {"images": images})


def image_stack(folder, name, width, height, scales):
    layers = (("Front", front), ("Back", back))
    for layer, draw in layers:
        contents(folder / f"{layer}.imagestacklayer", {})
        image_set(folder / f"{layer}.imagestacklayer/Content.imageset", f"{name}-{layer.lower()}", width, height,
                  scales, draw)
    contents(folder, {"layers": [{"filename": f"{layer}.imagestacklayer"} for layer, _ in layers]})


def tv():
    folder = CATALOG / TV
    image_stack(folder / "App Icon.imagestack", "icon", 400, 240, (1, 2))
    image_stack(folder / "App Icon - App Store.imagestack", "icon-store", 1280, 768, (1,))
    image_set(folder / "Top Shelf Image.imageset", "top-shelf", 1920, 720, (1, 2), on_background)
    image_set(folder / "Top Shelf Image Wide.imageset", "top-shelf-wide", 2320, 720, (1, 2), on_background)
    contents(folder, {"assets": [
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide",
         "size": "2320x720"},
    ]})


def main():
    contents(CATALOG, {})
    app_icon()
    tv()
    print(f"Generated {CATALOG.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
