"""Generate the DSH Voice app icon.

Small sizes get a simplified, bolder glyph: a thin stem and base bar turn to mush
at 16-32 px, so below 48 px the microphone is drawn as a capsule plus a thick arc.

Usage: python make-icon.py <out_dir>
"""
import os
import sys

from PIL import Image, ImageDraw

BRAND_TOP = (86, 134, 254)     # deepseek-450
BRAND_BOTTOM = (65, 118, 230)  # deepseek-500
SS = 8                         # supersampling factor per target size


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw(size: int) -> Image.Image:
    S = size * SS
    # gradient tile
    grad = Image.new("RGB", (S, S))
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(BRAND_TOP, BRAND_BOTTOM, y / (S - 1)))

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=255)
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), mask)
    grad.close()

    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)
    white = (255, 255, 255, 255)

    # Equalizer bars: three rounded bars stay legible down to 16 px, where a
    # detailed microphone collapses into a blob.
    small = size <= 32
    bar_w = S * (0.155 if small else 0.135)
    gap = S * (0.072 if small else 0.078)
    heights = (0.32, 0.50, 0.38) if small else (0.34, 0.52, 0.40)
    total = 3 * bar_w + 2 * gap
    x0 = S * 0.5 - total / 2
    cy = S * 0.5
    for i, hf in enumerate(heights):
        hh = S * hf
        x = x0 + i * (bar_w + gap)
        d.rounded_rectangle([x, cy - hh / 2, x + bar_w, cy + hh / 2], radius=bar_w / 2, fill=white)

    out = Image.alpha_composite(icon, art)
    icon.close()
    art.close()
    return out.resize((size, size), Image.LANCZOS)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    sizes = [16, 24, 32, 48, 64, 128, 256]
    frames = {s: draw(s) for s in sizes}

    for s in (32, 64, 256):
        frames[s].save(os.path.join(out, f"icon-{s}.png"))

    frames[256].save(os.path.join(out, "favicon.ico"),
                     sizes=[(s, s) for s in sizes])
    frames[256].save(os.path.join(out, "icon.ico"), sizes=[(s, s) for s in sizes])
    print("wrote icons:", ", ".join(f"{s}px" for s in sizes))


if __name__ == "__main__":
    main()
