"""Generate the client's own opaque iOS app icon and required asset sizes."""
import json
import math
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Telegram" / "Telegram-iOS" / "LocalGramAssets.xcassets" / "LocalGram.appiconset"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGB", (1024, 1024))
    pixels = image.load()
    for y in range(1024):
        for x in range(1024):
            t = (x + y) / 2048
            pixels[x, y] = (int(27 + 41 * t), int(29 + 19 * t), int(62 + 89 * t))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((210, 453, 814, 804), radius=58, fill=(235, 227, 255))
    draw.rounded_rectangle((178, 375, 846, 491), radius=36, fill=(249, 245, 255))
    draw.rectangle((465, 379, 559, 804), fill=(147, 125, 249))
    draw.rounded_rectangle((292, 253, 491, 386), radius=54, outline=(235, 227, 255), width=35)
    draw.rounded_rectangle((533, 253, 732, 386), radius=54, outline=(235, 227, 255), width=35)
    points = []
    for i in range(10):
        angle = -math.pi / 2 + i * math.pi / 5
        radius = 133 if i % 2 == 0 else 60
        points.append((773 + math.cos(angle) * radius, 239 + math.sin(angle) * radius))
    draw.polygon(points, fill=(255, 211, 86))
    sizes = [
        ("iphone", 20, 2), ("iphone", 20, 3), ("iphone", 29, 2), ("iphone", 29, 3),
        ("iphone", 40, 2), ("iphone", 40, 3), ("iphone", 60, 2), ("iphone", 60, 3),
        ("ipad", 20, 1), ("ipad", 20, 2), ("ipad", 29, 1), ("ipad", 29, 2),
        ("ipad", 40, 1), ("ipad", 40, 2), ("ipad", 76, 1), ("ipad", 76, 2),
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
    print("Generated LocalGram app icon assets.")


if __name__ == "__main__":
    main()
