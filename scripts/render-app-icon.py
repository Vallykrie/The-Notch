"""Procedural app icon for The Notch: the pixel mascot on a CRT, under the notch.

Everything is drawn from geometry — no bitmap inputs — at 4x supersampling, so every size
from 1024 down is a clean downsample of the same master.
"""
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 4
N = 1024
S = N * SS

TINT = {
    "working": (41, 158, 255), "thinking": (189, 107, 255), "tool": (77, 224, 255),
    "approval": (255, 133, 20), "question": (255, 204, 26), "done": (56, 255, 115),
}


def mix(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def squircle_mask(size, inset, n=5.0):
    """macOS-style continuous-corner tile: a superellipse in the 824pt body of a 1024 canvas."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    r = (size - 2 * inset) / 2
    d = (np.abs(x - c) / r) ** n + (np.abs(y - c) / r) ** n
    return Image.fromarray(((d <= 1) * 255).astype(np.uint8), "L")


def vgradient(size, top, bottom):
    t = np.linspace(0, 1, size, dtype=np.float32)[:, None, None]
    arr = np.array(top, np.float32) * (1 - t) + np.array(bottom, np.float32) * t
    return Image.fromarray(np.repeat(arr, size, axis=1).astype(np.uint8), "RGB")


def notch_mask(size, cx, top, width, height, r_bottom, r_shoulder):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    xl, xr = cx - width / 2, cx + width / 2
    d.rounded_rectangle([xl, top - r_bottom * 2, xr, top + height], radius=r_bottom, fill=255)
    # Concave shoulders where the notch meets the top edge.
    d.rectangle([xl - r_shoulder, top - 1, xr + r_shoulder, top + r_shoulder], fill=255)
    d.ellipse([xl - 2 * r_shoulder, top, xl, top + 2 * r_shoulder], fill=0)
    d.ellipse([xr, top, xr + 2 * r_shoulder, top + 2 * r_shoulder], fill=0)
    return m


# ---- the mascot -------------------------------------------------------------------------------
BODY = [(3, 4, 7), (4, 2, 9), (5, 1, 10), (6, 1, 10), (7, 2, 9)]


def mascot_cells(eyes="open", lift=2, legs=0):
    parts = {}
    for r, a, b in BODY:
        for c in range(a, b + 1):
            parts[(c, r)] = "body"
    for root, direction in ((4, -1), (7, 1)):
        parts[(root, 2)] = "ant"
        for s in range(1, lift + 1):
            parts[(root + direction * s, 2 - s)] = "tip" if s == lift else "ant"
    leg = [(3, 8), (4, 8), (7, 8), (8, 8), (2, 9), (9, 9)] if legs == 0 else \
          [(2, 8), (3, 8), (8, 8), (9, 8), (4, 9), (7, 9)]
    for p in leg:
        parts[p] = "leg"
    glints = []
    rows = [5, 4] if eyes == "wide" else [5]
    for start in (3, 7):
        for o in (0, 1):
            for r in rows:
                parts.pop((start + o, r), None)
        if eyes == "wide":
            glints.append((start, 4))
    cells = []
    # Shade as if the eyes were not there, so the face stays one clean surface.
    occ = set(parts) | {(start + o, r) for start in (3, 7) for o in (0, 1) for r in rows}
    for (c, r), k in parts.items():
        if k == "leg":
            tone = "lo"
        elif k == "tip" or (c, r - 1) not in occ:
            tone = "hi"
        elif (c, r + 1) not in occ:
            tone = "lo"
        else:
            tone = "base"
        cells.append((c, r, tone))
    cells += [(c, r, "white") for c, r in glints]
    return cells


def draw_mascot(layer, glow, x0, y0, cell, tint, eyes="open", alpha=255):
    d, g = ImageDraw.Draw(layer), ImageDraw.Draw(glow)
    gap = cell * 0.09
    colors = {"base": tint, "hi": mix(tint, (255, 255, 255), .42), "lo": mix(tint, (0, 0, 0), .36),
              "white": (255, 255, 255)}
    for c, r, tone in mascot_cells(eyes):
        box = [x0 + c * cell + gap, y0 + r * cell + gap, x0 + (c + 1) * cell - gap, y0 + (r + 1) * cell - gap]
        d.rectangle(box, fill=colors[tone] + (alpha,))
        g.rectangle([x0 + c * cell, y0 + r * cell, x0 + (c + 1) * cell, y0 + (r + 1) * cell], fill=colors[tone] + (alpha,))


def outer_band(mask, r):
    """A soft band just outside a mask's edge, without an O(k²) rank filter."""
    return ImageChops.subtract(mask.filter(ImageFilter.GaussianBlur(r)).point(lambda v: min(255, v * 2)), mask)


def inner_band(mask, r):
    return ImageChops.subtract(mask, mask.filter(ImageFilter.GaussianBlur(r)).point(lambda v: 255 if v > 250 else 0))


def bloom(glow, radius, strength):
    b = glow.filter(ImageFilter.GaussianBlur(radius))
    arr = np.asarray(b).astype(np.float32)
    arr[..., 3] *= strength
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")


def add(base, layer):
    """Additive blend of an RGBA layer onto an RGB image — light only ever brightens."""
    b = np.asarray(base).astype(np.float32)
    l = np.asarray(layer).astype(np.float32)
    a = l[..., 3:4] / 255
    return Image.fromarray((b + l[..., :3] * a).clip(0, 255).astype(np.uint8), "RGB")


def scanlines(size, top, bottom, period, strength):
    m = np.ones((size, size), np.float32)
    rows = np.arange(size)
    dark = (rows % period) < period * 0.42
    band = (rows >= top) & (rows <= bottom)
    m[dark & band, :] = 1 - strength
    return m


# ---- compositions -----------------------------------------------------------------------------
INSET = 100 * SS  # 824pt body inside a 1024 canvas, per the macOS icon grid


def finish(tile_rgb, mask, rim=True):
    """Clip to the tile, add a hairline rim light and the standard drop shadow."""
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sm = mask.filter(ImageFilter.GaussianBlur(14 * SS))
    shadow.putalpha(sm.point(lambda v: int(v * .45)))
    canvas.alpha_composite(shadow, (0, 10 * SS))
    tile = tile_rgb.convert("RGBA")
    if rim:
        edge = inner_band(mask, 3 * SS)
        grad = np.linspace(1, .15, S, dtype=np.float32)[:, None]
        e = (np.asarray(edge).astype(np.float32) * grad * .35).astype(np.uint8)
        white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
        white.putalpha(Image.fromarray(e, "L"))
        tile.alpha_composite(white)
    tile.putalpha(mask)
    canvas.alpha_composite(tile)
    return canvas.resize((N, N), Image.LANCZOS)


def peek():
    """A: a wide notch hanging from a coloured wallpaper, the mascot glowing inside it."""
    mask = squircle_mask(S, INSET)
    bg = vgradient(S, (52, 70, 190), (18, 16, 52))
    # A soft wash of the status palette across the wallpaper.
    wash = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wash)
    wd.ellipse([S * .05, S * .55, S * .7, S * 1.15], fill=(189, 107, 255, 120))
    wd.ellipse([S * .45, S * .6, S * 1.05, S * 1.1], fill=(41, 158, 255, 110))
    wash = wash.filter(ImageFilter.GaussianBlur(90 * SS))
    bg = Image.alpha_composite(bg.convert("RGBA"), wash).convert("RGB")
    top = INSET
    nm = notch_mask(S, S / 2, top, 620 * SS, 400 * SS, 120 * SS, 40 * SS)
    black = Image.new("RGB", (S, S), (0, 0, 0))
    bg.paste(black, (0, 0), nm)
    # Screen lip glow along the notch's lower edge, like the attention ring.
    lip = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ring = outer_band(nm, 4 * SS)
    lip.paste((120, 190, 255, 255), (0, 0), ring)
    bg = add(bg, bloom(lip, 10 * SS, .9))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cell = 31 * SS
    draw_mascot(layer, glow, S / 2 - 6 * cell, top + 52 * SS, cell, TINT["working"])
    bg = add(bg, bloom(glow, cell * .55, .75))
    bg.paste(layer, (0, 0), layer)
    return finish(bg, mask)


def arcade():
    """B: the whole tile is a CRT, one big phosphor mascot, the notch a dark bite at the top."""
    mask = squircle_mask(S, INSET)
    bg = vgradient(S, (10, 12, 22), (3, 4, 9))
    vign = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(vign).ellipse([S * .2, S * .25, S * .8, S * .85], fill=(41, 158, 255, 60))
    bg = Image.alpha_composite(bg.convert("RGBA"), vign.filter(ImageFilter.GaussianBlur(120 * SS))).convert("RGB")
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cell = 46 * SS
    draw_mascot(layer, glow, S / 2 - 6 * cell, S / 2 - 4.2 * cell, cell, TINT["working"])
    bg = add(bg, bloom(glow, cell * .45, .7))
    bg.paste(layer, (0, 0), layer)
    arr = np.asarray(bg).astype(np.float32) * scanlines(S, 0, S, 7 * SS, .22)[..., None]
    bg = Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGB")
    nm = notch_mask(S, S / 2, INSET, 340 * SS, 104 * SS, 44 * SS, 24 * SS)
    bg.paste(Image.new("RGB", (S, S), (0, 0, 0)), (0, 0), nm)
    return finish(bg, mask)


def squad():
    """C: graphite tile, the notch lit by the status spectrum, three agents at work inside it."""
    mask = squircle_mask(S, INSET)
    bg = vgradient(S, (44, 46, 58), (16, 17, 23))
    top = INSET
    w, h = 720 * SS, 380 * SS
    nm = notch_mask(S, S / 2, top, w, h, 110 * SS, 40 * SS)
    # Spectrum glow under the notch rim: blue → violet → orange → green, left to right.
    stops = [TINT["working"], TINT["thinking"], TINT["approval"], TINT["done"]]
    xs = np.linspace(0, 1, S, dtype=np.float32)
    seg = np.clip(xs * (len(stops) - 1), 0, len(stops) - 1 - 1e-6)
    i = seg.astype(int)
    f = (seg - i)[:, None]
    st = np.array(stops, np.float32)
    row = st[i] * (1 - f) + st[i + 1] * f
    spectrum = np.repeat(row[None, :, :], S, axis=0)
    ring = outer_band(nm, 8 * SS)
    ring_a = np.asarray(ring).astype(np.float32)[..., None]
    halo = np.concatenate([spectrum, ring_a], axis=2).astype(np.uint8)
    halo_img = Image.fromarray(halo, "RGBA")
    bg = add(bg, bloom(halo_img, 22 * SS, 1.0))
    bg = add(bg, bloom(halo_img, 4 * SS, .9))
    bg.paste(Image.new("RGB", (S, S), (0, 0, 0)), (0, 0), nm)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cell = 18 * SS
    y = top + h - 10 * cell - 46 * SS
    for k, tint in enumerate([TINT["working"], TINT["approval"], TINT["done"]]):
        cx = S / 2 + (k - 1) * 13 * cell
        draw_mascot(layer, glow, cx - 6 * cell, y, cell, tint)
    bg = add(bg, bloom(glow, cell * .6, .8))
    bg.paste(layer, (0, 0), layer)
    return finish(bg, mask)


SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


if __name__ == "__main__":
    # Usage: render-app-icon.py [appiconset-dir]   (default: the app's AppIcon.appiconset)
    # "B · Arcade" is the shipping icon; peek() and squad() are the alternatives it was chosen over.
    import os
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        here, "..", "The Notch", "Assets.xcassets", "AppIcon.appiconset")
    master = arcade()
    for size, scale in SIZES:
        px = size * scale
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out, f"icon_{size}x{size}@{scale}x.png"))
    print("wrote", len(SIZES), "icons to", os.path.normpath(out))
