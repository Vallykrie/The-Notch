# The Notch

macOS notch app: a notch shell (media, HUD, crypto) plus a live control surface for AI coding
agents (session status, permission/question alerts, plan review, jump-back, usage/cost).
Open source under the MIT licence.

## Read first

1. [docs/ROADMAP.md](docs/ROADMAP.md) — phases and progress. **The source of truth for status.**
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design, agent integration, licensing.
3. [tools/notch-hook/PROTOCOL.md](tools/notch-hook/PROTOCOL.md) — the hook ↔ app contract.
4. `docs/STATE.md`, if present — the maintainer's local working notes (not in git).

## Ground rules

- **Write original code.** Do not copy code from other notch or agent apps. Code from other
  projects is only acceptable under an MIT-compatible licence (MIT/BSD/Apache-2.0/ISC/Zlib,
  OFL for fonts), with its notice recorded in `THIRD_PARTY_LICENSES`. GPL code cannot be
  merged into this MIT project.
- **Do not re-enable App Sandbox.** The app cannot function sandboxed, which also means the Mac
  App Store is not a target. Ship via GitHub Releases + Homebrew. ARCHITECTURE §4a explains why.
- **Animation quality is a hard requirement.** Every spring/duration/radius lives in
  `Core/Theme.swift`; surfaces never hardcode curves. One spring per gesture, driven by one
  state enum.
- **Never clobber the user's agent config.** `~/.claude/settings.json` and
  `~/.codex/hooks.json` often contain hooks from other tools. Merge, back up, be idempotent.
  Never write to the real files in a test — inject a fake home.
- **Hooks must fail open.** A bug in our hook client must never block or break the user's agent.
- **No personal data in the repo.** Use placeholder paths (`/Users/you/…`) in previews, tests
  and docs; never commit secrets, tokens or signing material.
- Keep the roadmap honest: update the checkbox in the same commit as the code.

## Build

```bash
xcodebuild -project "The Notch.xcodeproj" -scheme "The Notch" \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Target: macOS 14+, `LSUIElement` (no Dock icon), universal binary.
