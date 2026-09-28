# The Notch — Architecture

> Design notes for The Notch. This is the technical companion to [ROADMAP.md](ROADMAP.md).
> Read this before implementing any phase.

## 0. This is an original app

**The Notch is written from scratch** and released under the MIT licence. Other notch utilities
and agent dashboards informed what the experience should *feel* like; none of their code,
assets, icons, fonts, or strings are used here.

- **Do not copy code from other projects** unless its licence is MIT-compatible (MIT, BSD,
  Apache-2.0, ISC, Zlib) and the notice is recorded in `THIRD_PARTY_LICENSES`. GPL code in
  particular cannot be merged into an MIT project.
- The agent integration is built on the **documented hook systems of the agent CLIs
  themselves** (Claude Code, Codex, Gemini CLI, …). That is a public integration point any app
  can implement.

## 1. What we are building

A macOS notch app with two halves:

| Half | What it does |
|---|---|
| **Notch shell** | The window over the physical notch, expand/collapse motion, and system surfaces (media, HUD, crypto) |
| **Agent surface** | Live AI-agent session status, approve-from-the-notch, plan review, jump-back, usage/cost |

The result: **the notch is both a media/system HUD and a live control surface for AI coding agents.**

## 2. The notch shell — how this class of app works

Requirements for the shell, written in our own terms.

### Window strategy
A borderless, non-activating `NSPanel` at roughly `.statusBar` level, positioned over the
physical notch via `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea`. Drawing *above* fullscreen
apps requires punching through the normal window level rules — the `SkyLightWindow` package does
this, and is the one dependency we will likely take for the shell. Multi-display and
display-reconnect handling is our own (`ScreenGeometry`).

### Animation targets
These are the curve *shapes* that make this class of app feel right — a fast, slightly
underdamped open, a critically-damped resize so panels don't wobble, and a plain crossfade for
content. Use them as starting values and tune on hardware:

```swift
.spring(response: 0.5,  dampingFraction: 0.6, blendDuration: 0.5)  // notch open/close
.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)    // non-bouncy resize
.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
.spring(response: 0.36, dampingFraction: 0.7)
.spring(response: 0.3,  dampingFraction: 0.6)
.smooth(duration: 0.3) / .smooth(duration: 0.35)                   // content crossfade
.spring(.bouncy(duration: 0.4))                                    // playful accents
```

Rules we adopt:
- **One spring per gesture**, driven by a single source-of-truth state enum — never
  animate width and height with different curves.
- **The aperture is the animation; content is uncovered, not faded in.** Corrected
  2026-08-08 after review on hardware: the "plain crossfade for content" noted
  above is wrong for the open/close gesture. Content is laid out at its *destination* size
  immediately and its layout is explicitly excluded from the transaction
  (`.animation(nil, value: state)`); only the clipping frame springs. Animating the content's
  own frame makes it reflow and squeeze for the whole gesture, which reads as a panel fading
  in rather than the notch stretching open. The under-damped open (0.6) is load-bearing here —
  the overshoot is what sells the stretch.
- `matchedGeometryEffect` is **not** used for the collapsed↔expanded pair. Both branches would
  declare the same ids as sources, which is only safe while the transition is `.identity` —
  i.e. only while nothing animates. It stays available for within-surface promotion.
- Never animate on `@Published` cascades — coalesce into one `withAnimation` block.
- Every curve lives in `Core/Theme.swift`. Surfaces never hardcode one.

### Dependencies we may take (all general-purpose, none app-specific)
`SkyLightWindow` (draw above fullscreen), `Sparkle` (updates), `Defaults`,
`KeyboardShortcuts`, `LaunchAtLogin-Modern`. Chosen on their own merits, not because another
app uses them. Currently **zero** dependencies are wired up; the shell and bridge are pure
SwiftUI/AppKit/Foundation.

**Now-playing data** needs the private MediaRemote framework, which since macOS 15.4 must be
driven out of process. Plan on a small XPC helper when Phase 6 starts.

## 3. Agent integration — how it works

The Notch does **not** parse terminal output or scrape logs. It registers a **hook** in each
agent CLI's own config, pointing at the bundled `notch-hook` binary. For Codex, in
`~/.codex/hooks.json`:

```json
{"hooks": {
  "PermissionRequest": [{"hooks": [{"type": "command", "timeout": 7200,
     "command": "'~/.the-notch/bin/notch-hook' --source codex"}]}],
  "SessionStart":  [{"matcher": "startup|resume|clear", "hooks": [{"timeout": 5, ...}]}],
  "PostToolUse":   [{"matcher": "", "hooks": [{"timeout": 5, ...}]}],
  "Stop":          [...], "SubagentStop": [...], "UserPromptSubmit": [...]
}}
```

**The `timeout: 7200` on `PermissionRequest` versus `timeout: 5` on everything else is the
whole trick.** Telemetry events are fire-and-forget. The permission hook *blocks the agent for
up to two hours* while `notch-hook` waits for the user to tap Allow/Deny in the notch, then
writes the decision to stdout for the CLI to consume. That is how "approve from the notch"
works with zero patching of the agent.

### Transport
`notch-hook` talks to the app over a Unix socket (`/tmp/the-notch.sock`, overridable with
`THE_NOTCH_SOCKET`) using newline-delimited JSON. The full contract — envelope fields, event
names, timeouts, and per-agent decision output — is in
[tools/notch-hook/PROTOCOL.md](../tools/notch-hook/PROTOCOL.md).

### Jump-back
Per-terminal strategies: AppleScript for iTerm2/Terminal, process-ancestry lookup to find the
owning terminal, and URL schemes for editors. See
[JUMPBACK.md](../The%20Notch/Integrations/JUMPBACK.md).

### Cost tracking
Session token counts come from hook payloads and local transcripts; cost = tokens × a price
table.

## 4. Target architecture for The Notch

```
The Notch/
  App/                  # @main, AppDelegate, NotchWindow (NSPanel), SkyLight, screen geometry
  Core/
    NotchState.swift        # single source of truth: .collapsed / .expanded / .peek(Activity)
    NotchCoordinator.swift  # nav + which surface owns the notch right now
    Theme.swift             # springs, radii, colors — ONE place, so animation stays coherent
  Surfaces/
    Media/  Shelf/  Calendar/  Battery/       # system surfaces
    Agents/                                    # live agent sessions
      AgentSessionStore.swift    # observable registry of live sessions
      SessionCard.swift          # collapsed pill + expanded card
      ApprovalSheet.swift        # blocking allow/deny UI
      PlanReviewView.swift       # markdown plan + feedback
      UsageMeter.swift
  AgentBridge/            # hook server, event model, config installer
    NotchHookServer.swift      # Unix socket listener, framed JSON, actor-isolated
    HookEvent.swift            # Codable envelope
    HookInstaller.swift        # writes/merges ~/.claude/settings.json, ~/.codex/hooks.json
    notch-hook/                # small Go (or Swift) client binary, cross-compiled
  Integrations/
    TerminalJumper.swift    # AppleScript + OSC-2 + URL schemes
    PricingCatalog.swift    # LiteLLM table + runtime refresh
  Settings/  Onboarding/
```

### Design decisions (locked)
1. **Hook-based, not scraping.** It is the only reliable way
   to get structured, real-time agent state.
2. **Merge, never clobber, user config.** A user's `~/.claude/settings.json` often already has
   hooks from other tools registered.
   `HookInstaller` must append our entry and back up first. Clobbering someone's agent
   config is unacceptable.
3. **Own hook binary.** A tiny static binary is the client; the Swift app is the server. Keeps
   the blocking-approval flow simple and works over SSH.
4. **One animation system.** `Theme.swift` owns every spring. Surfaces never hardcode curves.
5. **LSUIElement app**, macOS 14+, universal binary, Sparkle for updates.

## 4a. Licensing and distribution

**The Notch is open source under the MIT licence** (`LICENSE`). It is free; development is
funded by donations (see `.github/FUNDING.yml`).

- **Dependencies must be MIT-compatible.** Permissive licences only — MIT/BSD/Apache-2.0/ISC/
  Zlib, and OFL for fonts. Record each one in `THIRD_PARTY_LICENSES` and ship its notice
  inside the app. GPL/AGPL code cannot be merged; LGPL only if dynamically linked.
- Candidates already vetted: `SkyLightWindow` MIT, `Sparkle` MIT (plus bundled bsdiff BSD-2,
  sais-lite MIT, Ed25519 Zlib), `Defaults` MIT, `KeyboardShortcuts` MIT.

### The Mac App Store is not a viable target for this app
### The Mac App Store is not a viable target for this app

Not a licensing problem — a technical one, and it is structural rather than a detail to fix later.

**The Mac App Store requires App Sandbox.** This app cannot run sandboxed. Every one of its core
mechanisms is something the sandbox exists to prevent:

| What the app must do | Why the sandbox forbids it |
|---|---|
| Serve a Unix socket other processes connect to | `/tmp` is redirected into the app's container, so no agent CLI can reach it |
| Read and merge `~/.claude/settings.json`, `~/.codex/hooks.json` | Outside the container; no entitlement grants arbitrary dotfile access |
| Install `notch-hook` to `~/.the-notch/bin` for other apps to execute | Sandboxed apps cannot drop executables for third parties to run |
| Send AppleEvents to arbitrary terminals (jump-back) | Requires per-target temporary-exception entitlements, which review scrutinises heavily |
| Inspect process ancestry via `sysctl` to find the owning terminal | Restricted |

Disabling App Sandbox (Phase 0) was therefore not a shortcut — it is a precondition for the
product working at all.

**Plan for direct distribution instead:** Developer ID signing + notarization + Hardened Runtime
(already on), Sparkle for updates (Phase 7), GitHub Releases, and a Homebrew cask. This is the
standard path for utilities of this class and imposes no product compromises.
