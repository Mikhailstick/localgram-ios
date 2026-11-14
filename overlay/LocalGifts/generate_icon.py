"""Generate the client's own opaque iOS app icon and required asset sizes."""
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Telegram" / "Telegram-iOS" / "LocalGramAssets.xcassets" / "LocalGram.appiconset"

# Rounded, flowing arrow. Native geometry is shared with the UIKit branding renderer.
MARK_PATH = "M162 303 C141 292 138 266 156 247 C161 241 168 237 175 235 L413 153 C443 142 472 170 460 201 L375 472 C364 506 326 511 310 480 L292 444 C270 396 242 362 206 340 C186 326 174 309 162 303 Z"


def mark_mask(size):
    factor = size / 640.0
    points = [(162, 303)]

    def line(x, y):
        points.append((x, y))

    def curve(x1, y1, x2, y2, x3, y3):
        x0, y0 = points[-1]
        for index in range(1, 81):
            t = index / 80.0
            u = 1.0 - t
            points.append((u**3*x0 + 3*u*u*t*x1 + 3*u*t*t*x2 + t**3*x3,
                           u**3*y0 + 3*u*u*t*y1 + 3*u*t*t*y2 + t**3*y3))

    curve(141, 292, 138, 266, 156, 247)
    curve(161, 241, 168, 237, 175, 235)
    line(413, 153)
    curve(443, 142, 472, 170, 460, 201)
    line(375, 472)
    curve(364, 506, 326, 511, 310, 480)
    line(292, 444)
    curve(270, 396, 242, 362, 206, 340)
    curve(186, 326, 174, 309, 162, 303)
    mask = Image.new("L", (size, size))
    ImageDraw.Draw(mask).polygon([(x * factor, y * factor) for x, y in points], fill=255)
    return mask


def artwork():
    size = 1024
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (0.55 * x + 0.45 * y) / (size - 1)
            glow = math.exp(-(((x - 770) / 680) ** 2 + ((y - 290) / 760) ** 2))
            pixels[x, y] = (int(25 + 28 * t + 8 * glow), int(11 + 10 * t + 3 * glow), int(42 + 39 * t + 16 * glow))
    mask = mark_mask(size * 3).resize((size, size), Image.Resampling.LANCZOS)
    shadow = Image.new("L", (size, size))
    shadow.paste(mask, (0, 10))
    shadow = shadow.filter(ImageFilter.GaussianBlur(15)).point(lambda value: value // 5)
    image.paste((7, 3, 15), (0, 0, size, size), shadow)
    foreground = Image.new("RGB", (size, size))
    draw = ImageDraw.Draw(foreground)
    for y in range(size):
        t = max(0.0, min(1.0, (y - 220) / 590))
        draw.line((0, y, size, y), fill=(int(255 - 35 * t), int(251 - 47 * t), int(255 - 13 * t)))
    image.paste(foreground, (0, 0), mask)
    return image, mask


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    image, mask = artwork()
    image.save(ROOT.parent / "ExoraGram-icon.png")
    image.resize((640, 640), Image.Resampling.LANCZOS).save(ROOT.parent / "ExoraGram-icon-preview.png")
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 640 640"><defs><linearGradient id="bg" x2="1" y2="1"><stop stop-color="#210F3A"/><stop offset="1" stop-color="#3B1C5D"/></linearGradient><linearGradient id="mark" x2="0" y2="1"><stop stop-color="#FFFBFF"/><stop offset="1" stop-color="#DCCC F5"/></linearGradient></defs><rect width="640" height="640" fill="url(#bg)"/><path d="{MARK_PATH}" fill="url(#mark)"/></svg>'.replace("#DCCC F5", "#DCCCF5")
    (ROOT.parent / "ExoraGram-icon.svg").write_text(svg, encoding="utf-8")
    mark = Image.new("RGBA", image.size, (255, 255, 255, 0))
    mark.putalpha(mask)
    mark.save(ROOT.parent / "ExoraGram-mark.png")
    sizes = [
        ("iphone", 20, 2), ("iphone", 20, 3), ("iphone", 29, 2), ("iphone", 29, 3),
        ("iphone", 40, 2), ("iphone", 40, 3), ("iphone", 60, 2), ("iphone", 60, 3),
        ("ipad", 20, 1), ("ipad", 20, 2), ("ipad", 29, 1), ("ipad", 29, 2),
        ("ipad", 40, 1), ("ipad", 40, 2), ("ipad", 76, 2),
        ("ipad", 83.5, 2), ("ios-marketing", 1024, 1),
    ]
    entries = []
    for idiom, size, scale in sizes:
        name = f"{idiom}-{size}-{scale}x.png"
        pixels_size = int(size * scale)
        image.resize((pixels_size, pixels_size), Image.Resampling.LANCZOS).save(OUTPUT / name)
        entries.append({"idiom": idiom, "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    (OUTPUT / "Contents.json").write_text(json.dumps({"images": entries, "info": {"version": 1, "author": "xcode"}}, indent=2))
    (OUTPUT.parent / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}))
    # The default app-icon entry still uses this legacy asset filename for safe upgrades.
    image.resize((180, 180), Image.Resampling.LANCZOS).save(ROOT / "Telegram/Telegram-iOS/LocalGramIcon@3x.png")
    print("Generated ExoraGram app icon and preview (1024 x 1024, opaque RGB).")


if __name__ == "__main__":
    main()
