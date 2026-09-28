#!/usr/bin/env python3
"""Fail if the collapsed notch draws anything underneath the camera housing.

This exists because the notch cannot be screenshotted: the notch band is excluded from
screen captures, and an `LSUIElement` app cannot be granted screen recording. Rendering the
real view offscreen with `NOTCH_FRAMES=<dir>` and then *measuring the pixels* is the only
way this class of defect gets caught — and it is a class that has shipped here before. A
green build has already let four separate defects through, including a collapsed layout that
drew its content behind the housing.

Content crossing the physical camera housing is the worst outcome available to the collapsed
surface: the hardware is opaque, so the pixels are simply gone, and nothing about the render
looks wrong until you hold it up against a real machine.

Usage:
    python3 tools/frame-check/housing-collision.py <frame-dir> [--housing-width PT] [--scale N]

Exits non-zero if any `scenario-collapsed-*.png` has ink inside the housing band.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

# The silhouette is drawn on a mid-grey ground so its edge is legible; ink is the bright
# text and sprites on the near-black pill. These thresholds separate the three populations.
PILL_MAX_LUMA = 25
INK_MIN_LUMA = 130
# Dropped from every edge of the pill before looking for ink, so the rim hairline and its
# antialiasing are not mistaken for content.
RIM_INSET_PX = 6


def analyse(path: pathlib.Path, housing_width_pt: float, scale: int):
    pixels = np.asarray(Image.open(path).convert("RGB")).astype(int)
    luma = pixels.sum(axis=2) / 3

    dark = luma < PILL_MAX_LUMA
    rows = np.where(dark.any(axis=1))[0]
    if rows.size == 0:
        return None

    top, bottom = rows.min(), rows.max()
    cols = np.where(dark[top : bottom + 1].any(axis=0))[0]
    left, right = cols.min(), cols.max()

    # The housing is centred on the display, and the panel is centred on the housing.
    centre = pixels.shape[1] / 2
    half = housing_width_pt * scale / 2
    housing = (centre - half, centre + half)

    interior = luma[
        top + RIM_INSET_PX : bottom - RIM_INSET_PX,
        left + RIM_INSET_PX : right - RIM_INSET_PX,
    ]
    if interior.size == 0:
        return None

    ink_cols = np.where((interior > INK_MIN_LUMA).any(axis=0))[0] + left + RIM_INSET_PX
    if ink_cols.size == 0:
        return {"pill": (left, right), "housing": housing, "ink": None, "overlap": 0}

    overlap = ink_cols[(ink_cols > housing[0]) & (ink_cols < housing[1])]
    return {
        "pill": (left, right),
        "housing": housing,
        "ink": (ink_cols.min(), ink_cols.max()),
        "overlap": int(overlap.size),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frame_dir", type=pathlib.Path)
    parser.add_argument(
        "--housing-width",
        type=float,
        default=189.0,
        help="physical notch width in points (default: this Mac's 189)",
    )
    parser.add_argument("--scale", type=int, default=2, help="backing scale factor")
    args = parser.parse_args()

    frames = sorted(args.frame_dir.glob("scenario-collapsed-*.png"))
    if not frames:
        print(f"no collapsed scenarios found in {args.frame_dir}", file=sys.stderr)
        return 2

    failures = 0
    for frame in frames:
        result = analyse(frame, args.housing_width, args.scale)
        if result is None:
            print(f"{frame.name}: no pill found — skipped")
            continue

        if result["ink"] is None:
            print(f"{frame.name}: no ink (empty surface) — clear")
            continue

        verdict = "COLLISION" if result["overlap"] else "clear"
        if result["overlap"]:
            failures += 1
        print(
            f"{frame.name}: pill={result['pill']} "
            f"housing=({result['housing'][0]:.0f},{result['housing'][1]:.0f}) "
            f"ink={result['ink']} under-housing={result['overlap']}px  {verdict}"
        )

    if failures:
        print(f"\n{failures} scenario(s) draw content under the camera housing", file=sys.stderr)
        return 1

    print("\nall collapsed scenarios clear of the camera housing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
