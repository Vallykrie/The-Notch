# App icon

**B · Arcade**: the whole tile is a CRT. One big phosphor mascot (the `working` blue, with
the same 3-tone shading, cell gaps and bloom as `AgentActivityGlyph`) sits under a dark notch
bitten out of the top edge.

It is drawn procedurally, not generated as a picture, so every size is a clean downsample of
a pixel-exact 1024px master:

```bash
python3 scripts/render-app-icon.py
```

That regenerates every PNG in `The Notch/Assets.xcassets/AppIcon.appiconset` (needs Pillow and
numpy). The script also keeps the two runner-up designs, `peek()` and `squad()`. It replaced an
AI-generated graphite tile that had nothing to do with the app's look.
