#!/usr/bin/env python3
"""Generate The Notch's UI sound effects from scratch.

Everything here is synthesised from sine harmonics by this file. Nothing is sampled,
extracted, converted, or derived from any other application's assets. The WAVs in
`The Notch/Resources/Sounds/` are build products of this script and are regenerated
rather than hand-edited, so the "source" for the audio is this readable file rather
than an opaque binary blob.

Design brief
------------
The app's visual identity is Departure Mono (a pixel-grid typeface) with 8x8 sprites,
so the cues are deliberately chiptune-adjacent: band-limited pulse tones on a small
number of odd harmonics, plain two-note motifs, no reverb, no noise layers.

They are also deliberately *quiet and short*. These fire while the user is working in
another app; a cue that demands attention twice is worse than one that is missed once.
Every cue is under 260 ms and peaks well below full scale.

Usage
-----
    python3 tools/generate-sounds.py            # write + verify
    python3 tools/generate-sounds.py --verify   # verify existing files only

Standard library only (`wave`, `math`, `struct`). No numpy, no third-party audio code,
so it stays runnable from a clean checkout on any Python 3.9+.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
BIT_DEPTH = 16
CHANNELS = 1

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "The Notch" / "Resources" / "Sounds"

# Equal temperament, A4 = 440 Hz. Named so the motifs below read as music rather than
# as magic numbers.
G5 = 783.99
A5 = 880.00
F5 = 698.46
C6 = 1046.50
E6 = 1318.51


# --------------------------------------------------------------------------------------
# Synthesis primitives
# --------------------------------------------------------------------------------------


def pulse_sample(phase: float, rolloff: float, max_harmonic: int, freq: float) -> float:
    """One sample of a band-limited pulse tone.

    A naive square wave is a stack of odd harmonics at 1/n. Summing them explicitly
    (rather than hard-switching between +1 and -1) keeps everything below Nyquist, so
    the tone stays clean instead of aliasing into a fizz at these fairly high pitches.

    `rolloff` shapes the timbre by steepening the 1/n^rolloff harmonic decay:
      1.0 -> square, bright and buzzy (too harsh for a background cue)
      2.0 -> triangle, soft and flutey
      1.6-1.8 -> the sweet spot used here: recognisably 8-bit, but rounded.
    """
    total = 0.0
    norm = 0.0
    harmonic = 1
    while harmonic <= max_harmonic:
        if harmonic * freq >= 0.45 * SAMPLE_RATE:
            break
        weight = 1.0 / (harmonic ** rolloff)
        total += weight * math.sin(phase * harmonic)
        norm += weight
        harmonic += 2
    return total / norm if norm else 0.0


def note(
    freq: float,
    duration: float,
    peak: float,
    *,
    rolloff: float = 1.7,
    attack: float = 0.005,
    decay_tau: float = 0.055,
    glide_to: float | None = None,
    glide_start: float = 0.4,
) -> list[float]:
    """Render one note as a list of floats in roughly [-1, 1].

    Envelope: a short linear attack (long enough to avoid the click a hard start makes,
    short enough to still read as percussive), then an exponential decay with time
    constant `decay_tau`, then a linear release over the final 10 ms so the note lands
    on exact zero. Anything that ends mid-waveform pops.

    `glide_to` bends the pitch over the tail of the note, which is what makes the
    question cue sound interrogative rather than declarative.
    """
    count = int(SAMPLE_RATE * duration)
    release = min(0.010, duration * 0.25)
    release_start = duration - release
    max_harmonic = 9

    out: list[float] = []
    phase = 0.0
    for index in range(count):
        t = index / SAMPLE_RATE

        current = freq
        if glide_to is not None and t > duration * glide_start:
            span = duration * (1.0 - glide_start)
            progress = (t - duration * glide_start) / span if span > 0 else 1.0
            # Smoothstep, so the bend eases in instead of kinking.
            eased = progress * progress * (3.0 - 2.0 * progress)
            current = freq + (glide_to - freq) * eased

        phase += 2.0 * math.pi * current / SAMPLE_RATE

        env = 1.0
        if t < attack:
            env *= t / attack
        env *= math.exp(-t / decay_tau)
        if t > release_start:
            env *= max(0.0, (duration - t) / release)

        out.append(peak * env * pulse_sample(phase, rolloff, max_harmonic, current))
    return out


def mix(layers: list[tuple[float, list[float]]]) -> list[float]:
    """Sum notes at their start offsets, in seconds."""
    length = 0
    for offset, samples in layers:
        length = max(length, int(offset * SAMPLE_RATE) + len(samples))
    buffer = [0.0] * length
    for offset, samples in layers:
        start = int(offset * SAMPLE_RATE)
        for index, value in enumerate(samples):
            buffer[start + index] += value
    return buffer


def lowpass(buffer: list[float], cutoff: float) -> list[float]:
    """One-pole lowpass. Takes the last of the edge off the top harmonics so the cues
    sit behind whatever else the user is listening to rather than on top of it."""
    dt = 1.0 / SAMPLE_RATE
    rc = 1.0 / (2.0 * math.pi * cutoff)
    alpha = dt / (rc + dt)
    out: list[float] = []
    previous = 0.0
    for value in buffer:
        previous += alpha * (value - previous)
        out.append(previous)
    return out


def finalize(buffer: list[float], target_peak: float) -> list[float]:
    """Normalise to an exact peak and guarantee silence at both ends."""
    peak = max((abs(value) for value in buffer), default=0.0)
    if peak > 0:
        scale = target_peak / peak
        buffer = [value * scale for value in buffer]

    fade_in = int(SAMPLE_RATE * 0.002)
    fade_out = int(SAMPLE_RATE * 0.008)
    length = len(buffer)
    for index in range(min(fade_in, length)):
        buffer[index] *= index / fade_in
    for index in range(min(fade_out, length)):
        buffer[length - 1 - index] *= index / fade_out
    return buffer


def write_wav(path: Path, buffer: list[float]) -> None:
    frames = bytearray()
    for value in buffer:
        clamped = max(-1.0, min(1.0, value))
        frames += struct.pack("<h", int(clamped * 32767.0))
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(CHANNELS)
        handle.setsampwidth(BIT_DEPTH // 8)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))


# --------------------------------------------------------------------------------------
# The cues
# --------------------------------------------------------------------------------------


def approval() -> list[float]:
    """"An agent is blocked waiting on you."

    The only cue that is allowed to be assertive, because the agent is stalled until the
    user answers. A rising perfect fifth (A5 -> E6) with the second note overlapping the
    first: upward intervals read as a question/summons, and the fifth is consonant enough
    not to sound like an error alert. Brightest rolloff of the three, still not a square.
    """
    return finalize(
        lowpass(
            mix(
                [
                    (0.000, note(A5, 0.095, 0.85, rolloff=1.55, decay_tau=0.038)),
                    (0.078, note(E6, 0.165, 1.00, rolloff=1.60, decay_tau=0.058)),
                ]
            ),
            cutoff=6200,
        ),
        target_peak=0.26,
    )


def done() -> list[float]:
    """"An agent finished / went idle."

    Informational, not a summons. A descending perfect fourth (C6 -> G5) resolves
    downward and stops asking for anything; the near-triangle rolloff and the lower
    peak keep it under the approval cue in both brightness and loudness, which is the
    ordering the user should hear when both land in the same minute.
    """
    return finalize(
        lowpass(
            mix(
                [
                    (0.000, note(C6, 0.080, 0.75, rolloff=1.95, decay_tau=0.035)),
                    (0.070, note(G5, 0.180, 1.00, rolloff=2.00, decay_tau=0.062)),
                ]
            ),
            cutoff=4800,
        ),
        target_peak=0.15,
    )


def question() -> list[float]:
    """"An agent is asking you something."

    A single short tone that bends up a minor third at the tail (F5 -> A5). It is the
    shortest and quietest of the three on purpose: the underlying event is the noisiest
    one an agent emits, so the cue has to be nearly subliminal to be tolerable.
    """
    return finalize(
        lowpass(
            note(F5, 0.155, 1.00, rolloff=1.80, decay_tau=0.050, glide_to=A5, glide_start=0.45),
            cutoff=5200,
        ),
        target_peak=0.13,
    )


CUES = {
    "sfx-approval.wav": approval,
    "sfx-done.wav": done,
    "sfx-question.wav": question,
}


# --------------------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------------------


def verify(path: Path) -> bool:
    """Read a generated file back through `wave` and sanity-check it."""
    if not path.exists():
        print(f"  MISSING  {path.name}")
        return False
    with wave.open(str(path), "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        count = handle.getnframes()
        raw = handle.readframes(count)

    duration_ms = count / rate * 1000.0
    samples = struct.unpack(f"<{count}h", raw)
    peak = max(abs(value) for value in samples) / 32767.0

    problems = []
    if (channels, width, rate) != (CHANNELS, BIT_DEPTH // 8, SAMPLE_RATE):
        problems.append("unexpected format")
    if not 40.0 <= duration_ms <= 400.0:
        problems.append("duration outside 40-400 ms")
    if not 0.05 <= peak <= 0.35:
        problems.append("peak outside 0.05-0.35")
    if samples[0] != 0 or samples[-1] != 0:
        problems.append("does not start and end at zero")

    status = "ok" if not problems else "FAIL: " + ", ".join(problems)
    print(
        f"  {path.name:<20} {duration_ms:6.1f} ms  {rate} Hz  "
        f"{width * 8}-bit  {channels}ch  peak {peak:.3f}  {status}"
    )
    return not problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="only verify the existing files; do not regenerate",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_DIR,
        help="output directory (defaults to the app's Resources/Sounds)",
    )
    args = parser.parse_args()

    if not args.verify:
        print(f"Generating into {args.output}")
        for name, build in CUES.items():
            write_wav(args.output / name, build())

    print("Verifying:")
    ok = all(verify(args.output / name) for name in CUES)
    if not ok:
        print("At least one file failed verification.", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
