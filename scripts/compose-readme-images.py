#!/usr/bin/env python3
"""Composes the README's images from the app's own renders.

The notch cannot be screenshotted, so the panels come from `FrameDump` (preview data, rendered
transparent with `NOTCH_FRAMES_CLEAR=1`) and from `LiveCapture` recordings of the running app.
This script places them on a desktop — a wallpaper and a menu bar — exactly where the notch
sits, so the images look like the Mac they run on rather than like cut-outs on grey.

    NOTCH_FRAMES_CLEAR=1 NOTCH_FRAMES=/tmp/frames "The Notch.app/Contents/MacOS/The Notch"
    python3 scripts/compose-readme-images.py stills /tmp/frames docs/images
    python3 scripts/compose-readme-images.py gif /tmp/recording docs/images/notch-attention.gif

Every frame is the 2x panel (1920x640 for the 960x320pt panel), notch centred at the top.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

SCALE = 2
MENU_HEIGHT = 32 * SCALE
FONT = "/System/Library/Fonts/SFNS.ttf"


def wallpaper(width, height, seed=0):
    """A soft dusk gradient: deep blue at the top, violet, warm amber low on the right."""
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    u, v = x / width, y / height
    top = np.array([28, 30, 64], np.float32)
    mid = np.array([92, 58, 128], np.float32)
    low = np.array([214, 120, 92], np.float32)
    t = np.clip(v * 1.1 + (u - 0.5) * 0.35, 0, 1)[..., None]
    base = np.where(t < 0.55, top + (mid - top) * (t / 0.55), mid + (low - mid) * ((t - 0.55) / 0.45))
    glow = np.exp(-(((u - 0.78) / 0.35) ** 2 + ((v - 1.05) / 0.5) ** 2))[..., None]
    base = base + glow * np.array([60, 40, 10], np.float32)
    rng = np.random.default_rng(seed)
    base += rng.normal(0, 1.2, base.shape)  # a little grain, so gradients do not band
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


def menubar(canvas, notch_width_px):
    draw = ImageDraw.Draw(canvas, "RGBA")
    width = canvas.width
    draw.rectangle([0, 0, width, MENU_HEIGHT], fill=(18, 14, 30, 70))
    font = ImageFont.truetype(FONT, 26)
    bold = ImageFont.truetype(FONT, 26)
    try:
        bold.set_variation_by_name("Semibold")
    except Exception:
        pass
    x = 36
    for index, item in enumerate(["Ghostty", "Shell", "Edit", "View", "Window", "Help"]):
        draw.text((x, MENU_HEIGHT / 2), item, font=bold if index == 0 else font, fill=(255, 255, 255, 235), anchor="lm")
        x += draw.textlength(item, font=bold if index == 0 else font) + 40
        if x > width / 2 - notch_width_px / 2 - 120:
            break
    clock = "9:41"
    draw.text((width - 44, MENU_HEIGHT / 2), clock, font=font, fill=(255, 255, 255, 235), anchor="rm")


def desktop(frame, height, width, seed=0):
    """A `width` x `height` piece of the top of the screen: the top of a full-height wallpaper,
    the menu bar, then the notch panel over both — centred, where the hardware notch is."""
    canvas = wallpaper(width, 1200, seed).crop((0, 0, width, height))
    menubar(canvas, 400 * SCALE)
    left = (frame.width - width) // 2
    canvas.alpha_composite(frame.crop((left, 0, left + width, height)))
    return canvas


def round_corners(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, image.width - 1, image.height - 1], radius, fill=255)
    out = image.copy()
    out.putalpha(mask)
    return out


STILLS = {
    # README name: (FrameDump scenario, crop height in px, crop width in px)
    "panel-agents.png": ("expanded-subagents", 470, 1500),
    "panel-permission.png": ("expanded-approval", 470, 1500),
    "panel-question.png": ("expanded-approval-question", 470, 1500),
    "panel-media.png": ("expanded-media-lyrics", 470, 1500),
    "panel-crypto.png": ("expanded-trading-watchlist", 470, 1500),
    "panel-settings.png": ("expanded-settings", 470, 1500),
}

COLLAPSED = [
    ("collapsed-agents", "Agents working"),
    ("collapsed-approval", "Needs your approval"),
    ("collapsed-media-playing", "Now playing"),
    ("collapsed-hud-volume", "Volume HUD"),
    ("collapsed-trading", "Pinned crypto price"),
]


def stills(frames, out):
    for name, (scenario, height, width) in STILLS.items():
        frame = Image.open(os.path.join(frames, f"scenario-{scenario}.png")).convert("RGBA")
        image = round_corners(desktop(frame, height, width, seed=len(name)), 28)
        image.save(os.path.join(out, name), optimize=True)
        print("wrote", name, image.size)

    # The closed notch in five states: one slim strip of desktop per state, labelled.
    rows = []
    font = ImageFont.truetype(FONT, 30)
    for scenario, label in COLLAPSED:
        frame = Image.open(os.path.join(frames, f"scenario-{scenario}.png")).convert("RGBA")
        strip = desktop(frame, 120, 1200, seed=len(label))
        row = Image.new("RGBA", (1700, 120), (0, 0, 0, 0))
        row.alpha_composite(round_corners(strip, 22), (0, 0))
        ImageDraw.Draw(row).text((1250, 60), label, font=font, fill=(150, 150, 156, 255), anchor="lm")
        rows.append(row)
    sheet = Image.new("RGBA", (1700, len(rows) * 140 - 20), (0, 0, 0, 0))
    for index, row in enumerate(rows):
        sheet.alpha_composite(row, (0, index * 140))
    sheet.save(os.path.join(out, "notch-closed.png"), optimize=True)
    print("wrote notch-closed.png", sheet.size)


def gif(recording, out, crop=(1500, 520), width=900, step=1, frame_ms=47):
    """`frame_ms` is the recording's real interval: LiveCapture asks for 30fps and gets ~21."""
    files = sorted(glob.glob(os.path.join(recording, "rec-*.png")))[::step]
    frames = []
    for path in files:
        frame = Image.open(path).convert("RGBA")
        image = desktop(frame, crop[1], crop[0], seed=7)
        image = image.resize((width, round(crop[1] * width / crop[0])), Image.LANCZOS).convert("RGB")
        frames.append(image)
    # One palette for the whole recording, sampled across it: a palette taken from a single
    # frame drops the hues that frame lacks (the amber card, the green confetti).
    samples = frames[:: max(1, len(frames) // 16)]
    strip = Image.new("RGB", (frames[0].width, frames[0].height * len(samples)))
    for index, sample in enumerate(samples):
        strip.paste(sample, (0, index * frames[0].height))
    base = strip.quantize(colors=190, method=Image.Quantize.MEDIANCUT).getpalette()[: 190 * 3]
    # The status hues and their shades get reserved entries: they cover a few hundred pixels of
    # a frame that is mostly wallpaper, so a palette chosen by area alone washes them out.
    accents = []
    for hue in [(255, 133, 20), (255, 204, 26), (56, 255, 115), (41, 158, 255), (77, 224, 255), (189, 107, 255), (242, 239, 232)]:
        for level in (0.25, 0.4, 0.55, 0.7, 0.85, 1.0, 1.15, 1.3, 1.45):
            accents += [min(255, int(c * level if level <= 1 else c + (255 - c) * (level - 1) * 1.6)) for c in hue]
    palette = Image.new("P", (1, 1))
    palette.putpalette((base + accents)[: 256 * 3])
    quantized = [f.quantize(palette=palette, dither=Image.Dither.FLOYDSTEINBERG) for f in frames]
    quantized[0].save(out, save_all=True, append_images=quantized[1:], duration=frame_ms * step, loop=0, optimize=True)
    print("wrote", out, len(quantized), "frames", os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    mode, source, target = sys.argv[1:4]
    stills(source, target) if mode == "stills" else gif(source, target)
