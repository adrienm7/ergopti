#!/usr/bin/env python3
# tools/generate_flags.py

"""
==============================================================================
MODULE: Flag Icon Generator
DESCRIPTION:
Regenerates every language-picker flag (static/img/flags/{locale}.png) from
geometric primitives so they share the same size, color depth, and visual
quality. The previous bitmaps were inconsistent and a few (notably Sweden)
were visibly wrong.

FEATURES & RATIONALE:
1. Reproducible: every flag is drawn from documented constants so future
   tweaks (palette, ratio) only change one place.
2. Uniform: all output PNGs are 32x24 px, 8-bit RGB, which is what the
   AHK tray-menu icon API consumes most cleanly.
3. Simplified-but-recognizable: complex flags (UK Union Jack, China stars,
   Korea taegeuk, India chakra) use schematic stand-ins that still read
   correctly at 32x24 — at that size, photoreal detail is impossible
   anyway.
==============================================================================
"""

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw


# =====================================
# =====================================
# ======= 1/ Constants =======
# =====================================
# =====================================

# All flags are rendered at the same canvas size so the language menu rows
# stay aligned no matter which one the user has selected.
WIDTH = 32
HEIGHT = 24

# Output directory — relative to the repo root.
OUT_DIR = Path(__file__).resolve().parents[1] / "static" / "img" / "flags"

# National color palette. Sourced from each country's official flag
# specification when one exists; otherwise from Wikipedia's reference SVGs.
COLORS = {
    # Pan-European
    "white":        (255, 255, 255),
    "black":        (  0,   0,   0),
    # Nordic blues / yellows / reds
    "sv_blue":      (  0, 106, 167),
    "sv_yellow":    (254, 204,   0),
    "no_red":       (239,  43,  45),
    "no_blue":      (  0,  35, 149),
    "da_red":       (198,  12,  48),
    # France
    "fr_blue":      (  0,  35, 149),
    "fr_red":       (239,  65,  53),
    # Germany
    "de_red":       (221,   0,   0),
    "de_gold":      (255, 206,   0),
    # Italy
    "it_green":     (  0, 140,  69),
    "it_red":       (205,  33,  42),
    # Netherlands
    "nl_red":       (174,  28,  40),
    "nl_blue":      ( 33,  70, 139),
    # Spain
    "es_red":       (198,  11,  30),
    "es_yellow":    (255, 196,   0),
    # Russia / similar tricolors
    "ru_blue":      (  0,  57, 166),
    "ru_red":       (213,  43,  30),
    # Poland
    "pl_red":       (220,  20,  60),
    # Portugal
    "pt_green":     (  0, 102,  53),
    "pt_red":       (218,  41,  28),
    # Czech
    "cs_blue":      ( 17,  69, 126),
    "cs_red":       (215,  20,  26),
    # Ukraine
    "uk_blue":      (  0,  87, 183),
    "uk_yellow":    (255, 215,   0),
    # Turkey
    "tr_red":       (227,  10,  23),
    # China
    "zh_red":       (238,  28,  37),
    "zh_yellow":    (255, 222,   0),
    # Japan
    "ja_red":       (188,   0,  45),
    # Korea
    "ko_red":       (205,  46,  58),
    "ko_blue":      (  0,  71, 160),
    # India
    "in_saffron":   (255, 153,  51),
    "in_green":     ( 19, 136,   8),
    "in_navy":      (  0,   0, 128),
    # Israel
    "il_blue":      (  0,  56, 184),
    # Arabic — Saudi green (most recognisable single-flag stand-in for "ar")
    "ar_green":     (  0, 109,  41),
    # UK (English language pick)
    "uk_navy":      (  1,  33,  105),
    "uk_red":       (200,  16,  46),
}




# ==========================================
# ==========================================
# ======= 2/ Drawing primitives =======
# ==========================================
# ==========================================

def _new_canvas(color=(0, 0, 0)):
    """Return a fresh (image, draw) pair filled with `color`."""
    img = Image.new("RGB", (WIDTH, HEIGHT), color)
    return img, ImageDraw.Draw(img)


def _vstripes(*cols):
    """Vertical stripes left → right, equally divided."""
    img, d = _new_canvas()
    n = len(cols)
    edges = [round(i * WIDTH / n) for i in range(n + 1)]
    for i, col in enumerate(cols):
        d.rectangle([edges[i], 0, edges[i + 1] - 1, HEIGHT - 1], fill=col)
    return img


def _hstripes(*cols, weights=None):
    """Horizontal stripes top → bottom. `weights` overrides equal split."""
    img, d = _new_canvas()
    if weights is None:
        weights = [1] * len(cols)
    total = sum(weights)
    y = 0
    for col, w in zip(cols, weights):
        h = round(HEIGHT * w / total)
        d.rectangle([0, y, WIDTH - 1, y + h - 1], fill=col)
        y += h
    return img


def _nordic_cross(bg, fg, *, vx=10, vw=4, hy=10, hh=4):
    """
    Background `bg` with a Nordic cross of color `fg`.
    `vx`/`vw` — left edge and width of the vertical band.
    `hy`/`hh` — top edge and height of the horizontal band.
    Defaults are tuned for 32x24 with the cross offset toward the hoist,
    matching the real-world Nordic cross convention.
    """
    img, d = _new_canvas(bg)
    d.rectangle([0, hy, WIDTH - 1, hy + hh - 1], fill=fg)
    d.rectangle([vx, 0, vx + vw - 1, HEIGHT - 1], fill=fg)
    return img




# =====================================================
# =====================================================
# ======= 3/ Per-flag builders =======
# =====================================================
# =====================================================

def flag_sv():
    # Sweden: yellow Nordic cross on royal blue.
    return _nordic_cross(COLORS["sv_blue"], COLORS["sv_yellow"])


def flag_no():
    # Norway: red field with a white-bordered blue Nordic cross. We render
    # it as a white cross, then a thinner blue cross on top, exactly like
    # the official spec.
    img, d = _new_canvas(COLORS["no_red"])
    # White outline cross — 6 px thick.
    d.rectangle([0, 9, WIDTH - 1, 14], fill=COLORS["white"])
    d.rectangle([9, 0, 14, HEIGHT - 1], fill=COLORS["white"])
    # Inner blue cross — 2 px thick, centred in the white outline.
    d.rectangle([0, 11, WIDTH - 1, 12], fill=COLORS["no_blue"])
    d.rectangle([11, 0, 12, HEIGHT - 1], fill=COLORS["no_blue"])
    return img


def flag_da():
    return _nordic_cross(COLORS["da_red"], COLORS["white"])


def flag_fr():
    return _vstripes(COLORS["fr_blue"], COLORS["white"], COLORS["fr_red"])


def flag_de():
    return _hstripes(COLORS["black"], COLORS["de_red"], COLORS["de_gold"])


def flag_it():
    return _vstripes(COLORS["it_green"], COLORS["white"], COLORS["it_red"])


def flag_nl():
    return _hstripes(COLORS["nl_red"], COLORS["white"], COLORS["nl_blue"])


def flag_es():
    # 1 : 2 : 1 horizontal stripes — red, yellow, red.
    return _hstripes(COLORS["es_red"], COLORS["es_yellow"], COLORS["es_red"],
                     weights=[1, 2, 1])


def flag_ru():
    return _hstripes(COLORS["white"], COLORS["ru_blue"], COLORS["ru_red"])


def flag_pl():
    return _hstripes(COLORS["white"], COLORS["pl_red"])


def flag_pt():
    # Portuguese national flag: 2:3 split vertical green/red, with the
    # national shield centred on the seam. At 32x24 we render just the
    # green/red bands plus a small yellow circle as a schematic shield.
    img, d = _new_canvas(COLORS["pt_red"])
    d.rectangle([0, 0, 12, HEIGHT - 1], fill=COLORS["pt_green"])
    # Shield: a small yellow ring centred at the band seam.
    cx, cy, r = 12, HEIGHT // 2 - 1, 4
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=COLORS["es_yellow"], width=1)
    d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=COLORS["white"])
    d.ellipse([cx - 1, cy - 1, cx + 1, cy + 1], fill=COLORS["pt_red"])
    return img


def flag_cs():
    # Czechia: white over red horizontal with a blue triangle from the
    # hoist whose apex reaches the centre of the flag.
    img, d = _new_canvas()
    d.rectangle([0, 0, WIDTH - 1, HEIGHT // 2 - 1], fill=COLORS["white"])
    d.rectangle([0, HEIGHT // 2, WIDTH - 1, HEIGHT - 1], fill=COLORS["cs_red"])
    d.polygon([(0, 0), (0, HEIGHT - 1), (WIDTH // 2 - 1, HEIGHT // 2 - 1)],
              fill=COLORS["cs_blue"])
    return img


def flag_uk():
    # Ukraine: blue top, yellow bottom.
    return _hstripes(COLORS["uk_blue"], COLORS["uk_yellow"])


def flag_en():
    # English language → UK Union Jack (the language is associated with the
    # UK in the picker; the US flag would also be defensible but Union Jack
    # is the historical pick and matches the existing icon's intent).
    img, d = _new_canvas(COLORS["uk_navy"])
    # Diagonals — white then red on top.
    d.line([(0, 0), (WIDTH - 1, HEIGHT - 1)], fill=COLORS["white"], width=5)
    d.line([(WIDTH - 1, 0), (0, HEIGHT - 1)], fill=COLORS["white"], width=5)
    d.line([(0, 0), (WIDTH - 1, HEIGHT - 1)], fill=COLORS["uk_red"], width=2)
    d.line([(WIDTH - 1, 0), (0, HEIGHT - 1)], fill=COLORS["uk_red"], width=2)
    # Plus sign — wide white then narrower red.
    d.rectangle([0, HEIGHT // 2 - 3, WIDTH - 1, HEIGHT // 2 + 2], fill=COLORS["white"])
    d.rectangle([WIDTH // 2 - 3, 0, WIDTH // 2 + 2, HEIGHT - 1], fill=COLORS["white"])
    d.rectangle([0, HEIGHT // 2 - 1, WIDTH - 1, HEIGHT // 2], fill=COLORS["uk_red"])
    d.rectangle([WIDTH // 2 - 1, 0, WIDTH // 2, HEIGHT - 1], fill=COLORS["uk_red"])
    return img


def flag_ja():
    # White with a centred red disc — diameter ≈ 3/5 of the flag height.
    img, d = _new_canvas(COLORS["white"])
    r = 7
    cx, cy = WIDTH // 2, HEIGHT // 2
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=COLORS["ja_red"])
    return img


def flag_zh():
    # China: red field with one big yellow star and four smaller ones in
    # the upper-left quadrant. At 32x24 we approximate with simple discs;
    # full 5-point star drawing at this size is illegible.
    img, d = _new_canvas(COLORS["zh_red"])
    d.ellipse([4, 4, 10, 10], fill=COLORS["zh_yellow"])           # big star
    d.ellipse([12, 3, 14, 5],  fill=COLORS["zh_yellow"])
    d.ellipse([14, 6, 16, 8],  fill=COLORS["zh_yellow"])
    d.ellipse([14, 10, 16, 12], fill=COLORS["zh_yellow"])
    d.ellipse([12, 13, 14, 15], fill=COLORS["zh_yellow"])
    return img


def flag_ko():
    # South Korea: white field with the taegeuk (red/blue yin-yang) at the
    # centre and four schematic trigrams in the corners.
    img, d = _new_canvas(COLORS["white"])
    cx, cy, r = WIDTH // 2, HEIGHT // 2, 6
    # Disc split: top half red, bottom half blue (schematic of the taegeuk).
    d.pieslice([cx - r, cy - r, cx + r, cy + r], 180, 360, fill=COLORS["ko_red"])
    d.pieslice([cx - r, cy - r, cx + r, cy + r],   0, 180, fill=COLORS["ko_blue"])
    # The S-curve of a real taegeuk would need more pixels than we have;
    # we leave the simple split, which still reads as "Korean flag" at 32x24.
    # Trigrams — three short bars in each corner.
    for (x, y) in [(2, 2), (WIDTH - 8, 2), (2, HEIGHT - 5), (WIDTH - 8, HEIGHT - 5)]:
        for i in range(3):
            d.rectangle([x, y + i * 2, x + 5, y + i * 2], fill=COLORS["black"])
    return img


def flag_in():
    return _hstripes(COLORS["in_saffron"], COLORS["white"], COLORS["in_green"])


def flag_hi():
    # Hindi → India: same tricolor as flag_in() with the Ashoka chakra
    # approximated as a small navy ring on the white band.
    img = flag_in()
    d = ImageDraw.Draw(img)
    cx, cy, r = WIDTH // 2, HEIGHT // 2, 3
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=COLORS["in_navy"], width=1)
    return img


def flag_he():
    # Israel: white field with two horizontal blue stripes and a Star of
    # David approximated as a centred blue diamond outline.
    img, d = _new_canvas(COLORS["white"])
    d.rectangle([0, 3, WIDTH - 1, 5], fill=COLORS["il_blue"])
    d.rectangle([0, HEIGHT - 6, WIDTH - 1, HEIGHT - 4], fill=COLORS["il_blue"])
    # Star of David — two overlapping triangles, schematic at 32x24.
    cx, cy = WIDTH // 2, HEIGHT // 2
    d.polygon([(cx, cy - 4), (cx - 4, cy + 2), (cx + 4, cy + 2)],
              outline=COLORS["il_blue"])
    d.polygon([(cx, cy + 4), (cx - 4, cy - 2), (cx + 4, cy - 2)],
              outline=COLORS["il_blue"])
    return img


def flag_tr():
    # Turkey: red field with white crescent + 5-point star, both offset
    # toward the hoist. Schematic at 32x24: two overlapping discs make the
    # crescent and the star becomes a small white dot to its right.
    img, d = _new_canvas(COLORS["tr_red"])
    # Outer white disc.
    d.ellipse([10, 6, 22, 18], fill=COLORS["white"])
    # Inner red disc, offset right to carve out the crescent shape.
    d.ellipse([13, 7, 23, 17], fill=COLORS["tr_red"])
    # 5-point star — schematic dot.
    d.ellipse([22, 10, 26, 14], fill=COLORS["white"])
    return img


def flag_ar():
    # Arabic — no single official flag for the language. We use a solid
    # green field (the colour shared by Saudi Arabia, Libya pre-1969, the
    # Pan-Arab movement, etc.) with a white crescent so the icon still
    # reads as "Arab world".
    img, d = _new_canvas(COLORS["ar_green"])
    d.ellipse([10, 6, 22, 18], fill=COLORS["white"])
    d.ellipse([13, 7, 23, 17], fill=COLORS["ar_green"])
    return img




# ===================================
# ===================================
# ======= 4/ Driver =======
# ===================================
# ===================================

REGISTRY = {
    "ar": flag_ar,
    "cs": flag_cs,
    "da": flag_da,
    "de": flag_de,
    "en": flag_en,
    "es": flag_es,
    "fr": flag_fr,
    "he": flag_he,
    "hi": flag_hi,
    "it": flag_it,
    "ja": flag_ja,
    "ko": flag_ko,
    "nl": flag_nl,
    "no": flag_no,
    "pl": flag_pl,
    "pt": flag_pt,
    "ru": flag_ru,
    "sv": flag_sv,
    "tr": flag_tr,
    "uk": flag_uk,
    "zh": flag_zh,
}


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for locale, builder in sorted(REGISTRY.items()):
        img = builder()
        out_path = OUT_DIR / f"{locale}.png"
        img.save(out_path, "PNG", optimize=True)
        print(f"  wrote {out_path.relative_to(OUT_DIR.parents[2])} "
              f"({img.size[0]}x{img.size[1]})")
    print(f"\n{len(REGISTRY)} flag(s) regenerated under {OUT_DIR}.")


if __name__ == "__main__":
    main()
