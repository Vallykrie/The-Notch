# The Notch — Roadmap

**Status legend:** `[ ]` not started · `[~]` in progress · `[x]` done · `[!]` blocked

> This file is the **single source of truth for progress**. Update the checkbox and the
> "Last touched" line of a phase in the same commit that changes its code.
> For "what do I do right now", read [STATE.md](STATE.md).

---

## Crypto tracker `[~]`

Last touched: 2026-09-26. Current scope: Binance Spot crypto only.

- [x] Crypto surface, Binance pair search, watchlist, pin/unpin, persisted preferences.
- [x] Public Binance REST catalog and WebSocket ticker, reconnect and sleep/wake lifecycle.
- [x] Collapsed symbol/price with HUD and agent-attention priority; independent geometry policy tests.
- [x] Decimal formatting, source timestamps, stale/offline/closed state, subscription failure handling.
- [x] Remove US stock, IDX, and forex feed controls and provider integrations; archive older saved assets during migration.
- [ ] Full hardware interaction/performance acceptance with the public crypto feed.

See [crypto feed details](TRADING.md). The earlier multi-asset plan is historical.

## Phase 0 — Foundation `[~]`

Repo, docs, build config. No app behaviour.

- [x] Design the hook-based agent protocol → `ARCHITECTURE.md`, `tools/notch-hook/PROTOCOL.md`
- [x] Define the shell's window strategy, deps and animation idioms
- [x] Git repo + GitHub remote (`Vallykrie/The-Notch`, `main`)
- [x] `ARCHITECTURE.md`, `ROADMAP.md`, `CLAUDE.md`
- [x] Xcode project config: bundle id, `LSUIElement=true`, macOS 14 target, universal
      (Release `ARCHS=arm64 x86_64`; SwiftData template files deleted)
- [x] **App Sandbox disabled.** The template enabled it; sandboxed, `/tmp` is redirected into
      the app container so no agent CLI could reach our socket, and reading `~/.claude`,
      installing the hook binary, and AppleEvents jump-back would all be blocked. This app
      cannot be sandboxed. Hardened Runtime stays on.
- [ ] SPM dependencies added and resolving — **deferred**, see note below
- [x] CI: `.github/workflows/ci.yml` — build, Go vet/build/test for both modules, the hook
      harness, and a **theme-guard** job failing the build if any animation curve is declared
      outside `Core/Theme.swift` (verified locally: catches an injected violation, silent on a
      clean tree). Never executed on GitHub Actions yet.

> **SPM deferred deliberately.** The swarm sandbox has no network, so package
> resolution could not run. Nothing built so far needs a dependency. They become
> necessary at: `SkyLightWindow` (draw above fullscreen, Phase 1), `Sparkle`
> (Phase 7), `Defaults`/`KeyboardShortcuts`/`LaunchAtLogin` (Phase 7). Add via
> Xcode with network access.

**Last touched:** 2026-08-08 — project configured and unsandboxed; CI added. SPM still outstanding.

---

## Phase 1 — The Notch Shell `[~]`

The window and the animation. **Nothing else lands until this feels right**, because every
later surface inherits this motion. This is the phase the "as smooth as the reference" bar
applies to.

- [x] `NotchWindow`: borderless non-activating `NSPanel`, notch-aligned via
      `NSScreen.safeAreaInsets`, correct level, click-through where transparent
- [x] `NotchShape`: bezier with inverted top corner radii, scaling on expand
- [x] `NotchState` enum + `NotchCoordinator` as the single source of truth
- [x] `Theme.swift`: every spring/radius/duration centralised (see ARCHITECTURE §2).
      Verified: zero hardcoded curves anywhere outside `Theme.swift`.
- [x] Hover → expand, mouse-exit → collapse, with hysteresis (`NSTrackingArea`,
      60 ms enter / 220 ms exit delay, cancel-on-re-entry). **This never actually fired
      until 2026-08-08:** `hitTest` compared a point in the superview's unflipped space
      against a path built in the hosting view's flipped space, mirroring the live region
      to the bottom of the panel. The notch itself was click-through, so no `mouseEntered`
      ever arrived and the app appeared to have no animation at all.
- [x] Content promotion pill → panel, as a **reveal, not a crossfade**.
      `matchedGeometryEffect` was removed from the collapsed/expanded pairs: both branches
      declared the same ids as sources, which is only safe while the transition is
      `.identity` — i.e. while there is no animation. Content is now laid out at its
      destination size with its layout excluded from the transaction, and only the clipping
      aperture springs, so the notch stretches open over stationary content. An earlier
      opacity/blur crossfade was rejected on review as reading like a fading panel.
- [x] Multi-display + display-reconnect handling; non-notched Macs get a faux notch
- [x] **The app actually launches.** It did not before: `NotchWindow` called the `NSPanel`
      convenience initializer taking `screen:`, which funnels through a designated initializer
      the subclass never implemented — a guaranteed trap. A build check cannot catch this.
- [ ] Draws above fullscreen apps — **needs the `SkyLightWindow` SPM dep**; a clean
      seam and `TODO` are in place in `NotchWindow.swift`
- [ ] **Motion review on hardware, 60/120 Hz, no dropped
      frames** — not yet done; requires running the app on a real notched display.
      **This is the gate on the whole phase and only the user can open it.**
- [ ] Pixel-match `NotchShape` radii against a real notch
- [x] Nothing is ever drawn under the camera housing. The collapsed shell used to render a
      dot, "The Notch", the battery glyph and a chevron inside a silhouette exactly the size
      of the physical notch — invisible and clipped on notched hardware. The resting shell now
      renders nothing there; the agents surface grows a shoulder either side of the housing.

**Exit criteria:** open/close is indistinguishable from the references at normal speed, and
in slow-motion screen capture the curve is a single coherent spring.

**Last touched:** 2026-08-17 — the close was retuned after the user reported it as abrupt.
0.18s → 0.32s on a softer head (0.42/0/0.22/1), and `surfaceFade`, `contentExit`,
`contentEnter` and `contentEntry` were all rescaled with it: each had been tuned against the
old duration and resolved inside the first fifth of the new one, which is an empty box
deflating and a shadow leaving ahead of the panel that cast it. The close is now deliberately
*longer* than the open — see the reasoning on `Theme.Motion.close`; the two directions were
never symmetric problems.
**The side-by-side motion review that defines this phase's quality bar still has not
happened**, and the close retune above was judged from a description rather than beside the
references, so it is exactly the kind of change that review exists to confirm. Radii in
`Theme.Metrics` remain educated guesses until checked on hardware.

---

## Phase 2 — Agent Bridge `[~]`

The backbone of the AI feature. Headless — testable without any UI.

- [x] `HookEvent` Codable envelope + `JSONValue` for opaque payloads, `unknown` event fallback
- [x] `NotchHookServer`: Unix socket at `/tmp/the-notch.sock`, **newline-delimited JSON**,
      actor-isolated, stale-socket detection, `0600` perms, per-connection concurrency
- [x] `notch-hook` client binary (Go, stdlib only) — `go vet` and `go build` clean
- [x] Cross-compile matrix (darwin/linux/freebsd × amd64/arm64) via `tools/notch-hook/build.sh`
- [x] `HookInstaller`: merges into `~/.claude/settings.json` and `~/.codex/hooks.json`.
      **Verified empirically** against a copy of the real config: 15 pre-existing hooks
      survived, install is idempotent, backups written, uninstall restores the original
      exactly, malformed JSON is refused without writing.
- [x] Fail-open: with no server running, hooks exit 0 immediately and print nothing, so the
      CLI falls back to its own prompt. **Verified.**
- [x] Blocking approval round-trip implemented (`PermissionRequest`, timeout 7200,
      continuation resumed exactly once, `defer` on timeout)
- [x] Session lifecycle → `AgentSessionStore` with derived `SessionStatus`
- [x] **Server started by the app.** `AgentBridgeController` owns the server + store and
      surfaces the notch when an agent is blocked. Fixed two launch-blocking defects found by
      actually running the app: an `NSPanel` designated-initializer trap, and App Sandbox
      (which redirects `/tmp` into the container, so no CLI could ever have reached the socket).
- [x] **Live round-trip verified** through the real Go client: socket appears at `0600`,
      telemetry events accepted, `PermissionRequest` genuinely blocks the agent, client-killed
      and app-killed mid-approval both recover, and a stale socket is rebound on relaunch.
- [x] Integration test: `tools/hook-harness` (fake server + fake agent) with 6 scenarios —
      happy path, allow, deny, timeout, concurrent sessions, malformed input. `run-all.sh`
      passes 6/6, touching neither the real socket nor the real agent configs.
- [x] Permission-decision stdout shape — **resolved for Codex and Claude Code.**
      Established from the installed binaries' embedded schemas; see `tools/notch-hook/PROTOCOL.md`.
      This found a real bug: the client emitted a shape Codex rejects, so approve-from-the-notch
      silently never worked there. Fixed per-source.
- [x] Claude Code's `PermissionRequest` stdout contract — established from the 2.1.252 binary's
      schema: `hookSpecificOutput.decision.behavior` (+ `updatedInput` on allow), the same shape as
      Codex. The old top-level `permissionDecision` was silently ignored, so approving or answering
      from the notch never reached Claude and the terminal prompt stayed up. Fixed.
- [ ] End-to-end against a real `claude` / `codex` session driving it (the harness proves the
      protocol, not the CLIs' real behaviour)

- [x] **Approve/answer from the notch removed (2026-09-29).** Even with the corrected output
      shape, decisions made in the notch did not reliably land in Claude Code. The notch now
      announces permission prompts and questions only: the server replies `defer` at once so the
      terminal prompt appears immediately, and the notice clears when the session moves on or
      is clicked.

**Exit criteria:** `claude` and `codex` sessions appear, update, and can be approved from a
CLI harness with no UI attached.

**Last touched:** 2026-08-08 — wired into the app and verified live; harness green 6/6. Codex
approval fixed; Claude's decision shape remains the one unresolved protocol question.

---

## Phase 3 — Agent UI `[~]`

- [x] Collapsed pill: the dominant status as **the mascot** — one 12x12 pixel blob that acts
      out the state (`AgentActivityGlyph`). Was nine unrelated abstract marks on an 8x8 grid,
      before that a tinted agent sprite, and before that a status dot. The dot and the sprite
      put the whole message in hue, which is the channel that fails first at 8pt in peripheral
      vision; the nine marks fixed that and introduced a new problem, since marks that share no
      silhouette read as the indicator being swapped rather than as one agent changing what it
      is doing. A constant character with changing behaviour is both. Drawn as an arcade
      sprite — one flat saturated colour, eyes punched out as holes, a hairline gap between
      cells so the pixel grid is visible, and an additive bloom pass. Low and wide in every
      state; the whole creature fits the collapsed shoulder at a visible 2pt cell.
- [x] The mascot is **alive**, not just animated (concept D in `docs/design/mascot-concepts-v1.html`):
      3-tone shading from the status hue, 4-frame working bob, seeded natural blinks, one-shot
      reactions on a real state change (approval startle + "!", thinking glance, legs revving,
      done double-hop + confetti), fidgets in the calm states, eyes that follow the pointer over
      the expanded panel, sleep after long idle, and a beam-in for sessions that start while the
      app runs. Expanded rows get two rows of headroom so hops never clip an antenna; the
      collapsed shoulder has no effects and caps lifts instead.
- [x] Expanded session list; multiple concurrent sessions, ordered by **when the user last
      typed into each one** rather than by last activity. An agent in a long tool loop emits an
      event every few seconds and pinned itself to the top, pushing the session you had just
      given work to underneath it — and the collapsed shoulder, which draws the leading session,
      inherited the same mistake.
- [x] **Subagents are part of a row, not rows.** A `Task` subagent's hook events carry the
      parent's `session_id` plus an `agent_id` and `agent_type` of their own (verified on the
      live socket against Claude Code 2.1.227), so every one of them was landing on the parent's
      row and fighting over its status and current tool — the panel read as five agents running
      when one had delegated four times. They are now indented under their parent at a smaller
      mark, capped at three with a `+n more`, and cleared 90s after they finish.
- [x] **Agents launched by an agent are subagents too.** A headless run started from another
      agent's shell (`agy --print`, `codex exec`, `claude -p`) has a session id of its own and
      nothing in its payload naming its launcher, so a Claude session fanning out image
      generations filled the panel with one row per run, each kept 15 minutes. The hook peer's
      process tree now records every process above the agent; when one is another session's
      agent, the run goes under that session's row and clears 90s after its `Stop`.
- [x] Approval card: tool + input summary, Allow / Allow-always / Deny, `⏎` allows and `⎋` denies,
      elapsed-blocked time. Takes priority over the session list — an agent is stalled on it.
- [x] Plan review: `AttributedString` Markdown + feedback field (no dependency)
- [x] Per-agent identity via original 8x8 sprites — `PixelGlyph`, not SF Symbols. (This line
      claimed SF Symbols for months; the app has never shipped one and must not.) The session
      row and the approval card no longer *draw* the agent's sprite: it sat immediately beside
      the status mark and read as two icons competing for one job. Identity lives in the
      accessibility label and the project line; the row's opening is spent on what changes.
- [x] Attention motion: a light travelling the silhouette's **rim** while an agent is blocked
      (`AttentionRingView`), and a distinct motion per state on the mark itself. Both honour
      Reduce Motion. Replaces the pulse-and-halo, which was one shared pulse across four busy
      states and a *static* oversized ring on `needsApproval`.
- [x] Previews for the states that matter: empty, one session, concurrent, very long tool
      summary, done
- [x] **Question card** *(since made read-only — see Phase 2's removal note)* — the agent's own options as one-tap buttons, numbered `1`…`9` exactly
      as the CLI numbers them, with an "Other" field for anything it did not think to offer and
      *Ask in terminal* (`⎋`) to hand the question back untouched. `AskUserQuestion` arrives
      through the permission hook like a shell command does, and answering it *Allow Once* only
      bought the agent permission to ask again in the terminal. The answer travels back as
      `updated_input` → `updatedInput`: the same tool call with its `answers` map filled in.
      Parsed defensively (`ApprovalQuestion`) — any payload shape we cannot read falls back to
      the ordinary allow/deny card.
- [x] Attention *sound* — three original cues synthesised by `tools/generate-sounds.py`
      (approval / question / finished), rate-limited and mutable via the
      `NotchSoundEffectsEnabled` default. **Nobody has listened to them yet**; the mute toggle
      now has a settings UI (Phase 7, "Sound cues").
- [x] Hide a session from the panel — a per-row control on every session that is not blocking on
      an approval, plus "Clear Idle" in the header for the bulk case. Removes the row and nothing
      else; a hidden session reappears the moment it emits another event.
- [ ] Diff preview inside the approval card (currently a text summary only)
- [ ] Plan review is not wired to a store API — `PlanReviewRequest` is a local placeholder

**Last touched:** 2026-08-17 — every status got its own motion, and the attention ring was
rebuilt to trace the silhouette's rim instead of sweeping an angular gradient across it. Both
were verified by rendering filmstrips and sampling pixels, which found four defects no build
could have (see STATE). The approval path is still the part that matters and it is complete.
Never seen on a real notch.

---

## Phase 4 — Jump-back `[~]`

- [x] `TerminalJumper` + per-target strategy protocol; `JumpResult` distinguishes exact /
      approximate / app-only / failed, so the UI can be honest about what it managed
- [x] AppleScript: iTerm2 (window → tab → session, exact when the session id is known),
      Terminal.app (tab match by tty)
- [x] URL schemes: VS Code, Cursor, Zed (path-level, reported as approximate)
- [x] `ProcessAncestryStrategy` — walks the agent's process ancestry via `sysctl` to identify
      the owning terminal when the payload carries no hint
- [x] `AppleScriptRunner` with a hard timeout and TCC-denial (`-1743`) surfaced as a distinct,
      actionable error
- [x] `NSAppleEventsUsageDescription` configured
- [x] Wired into the panel: a ↗ on every session row, and "Open Agent to answer" on the
      approval card. The host app (terminal, IDE or desktop app) is found by walking up from
      the hook's socket peer at accept time, so no hook or agent config changed; Codex sessions
      seen only through their session files use its `originator` instead
- [ ] **Ghostty, WezTerm, Kitty, Warp, Zellij — not implemented.** Seams exist; these need
      OSC-2 / title probing. `JUMPBACK.md` says so plainly rather than implying coverage.
- [ ] First-run Automation-permission flow that explains itself
- [ ] **Never executed.** No AppleEvent has been sent — doing so triggers a real TCC prompt.
      Type-checked only; needs manual testing per terminal.
- [ ] Latent: `AppleScriptRunner` reads pipes only after exit, so >64KB of output would stall
      until the timeout. Low risk (these scripts return ~nothing) but worth hardening.

**Last touched:** 2026-10-03 — wired into the panel; host detection verified live for the Claude
desktop app. No AppleEvent jump has been exercised yet.

---

## Phase 5 — Usage & Cost `[~]`

- [ ] `PricingCatalog`: bundled LiteLLM-derived table + runtime refresh + offline fallback
- [x] Per-session token usage, read from the agent's own transcript
      (`TranscriptUsageReader`). Hook payloads carry no usage at all — the row's usage column
      had been reading fields that never arrive, which is why it was blank on every session.
      The transcript's `message.usage` is the source instead, read incrementally from a stored
      byte offset so an event storm costs a seek and the new bytes. The row shows **context**
      and **output**, not a cumulative total: with prompt caching a total climbs by the whole
      context every turn and reads like a runaway bill.
- [ ] Per-day rollup
- [ ] Provider quota windows with a "approaching limit" warning
- [ ] Usage surface in the expanded notch

**Last touched:** 2026-08-19 — per-session usage only; no pricing table, so cost appears only
when an agent states one itself.

---

## Phase 6 — System Surfaces `[~]`

Scope deliberately narrowed on 2026-08-12 at the user's direction: **battery and calendar were
removed outright.** They were commodity menu-bar widgets that had nothing to do with what this
app is for, and they were occupying the expanded panel that media and agents needed. The
surfaces are now exactly two — media and agents — and the notch shows both at once.

- [x] ~~Battery~~ — **removed.** `BatteryMonitor`, `BatteryStatus`, `BatteryGlyph`,
      `BatteryDetailView` and their `Theme` tokens are deleted.
- [x] ~~Calendar~~ — **removed.** `CalendarService`, `CalendarEventModel`, `EventRowView`,
      `UpcomingEventsView`, `CALENDAR.md` and the `NSCalendarsFullAccessUsageDescription`
      Info.plist key are deleted. The app now requests no TCC permission at launch at all.
- [x] **Media: now-playing** — title, artist, artwork, elapsed position. **MediaRemote was
      rejected**: it is a private framework, gated for unentitled apps since macOS 15.4. One
      `osascript` call per poll against Spotify and Music, and only against a player that is
      *already running* — scripting a dead app launches it and fires an unrequested Automation
      prompt. Fails open and silent, and backs off permanently on TCC denial.
- [x] **Media: controls** — play/pause, next, previous, and a draggable scrubber that seeks.
      Each command updates the UI optimistically and then reconciles against the next poll,
      because a 2s wait for the button to respond reads as a broken button.
- [x] **Media: artwork** — fetched only when the track identity changes. Spotify via its
      `artwork url` and one URLSession call (the app's only network request); Music by writing
      `data of artwork 1` to a temp file, since `osascript` cannot return binary on stdout.
      `NowPlayingStatus` compares artwork by identity, never by bytes.
- [x] **Media: lyrics** — synced lyrics from LRCLIB (`LyricsProvider`), fetched only while the
      user has lyrics on, cached per track. The panel switches to a stage layout (reel of wrapped
      lines, transport folded into a strip, one `lyricsMode` spring), and the collapsed notch
      shows the sung line split across the camera housing, its shoulders sized to the line.
      Spotify's artwork is therefore no longer the app's only network request.
- [x] **Both live activities are on screen at once, collapsed**, with the camera housing
      reserved as a real gap between them. Expanded, a `NotchTabBar` selects which one the
      panel elaborates.
- [x] **The collapsed notch is one idea per shoulder, at a narrow width.** `LiveActivityLayout`
      is the single source of truth for collapsed geometry: idle is exactly the hardware
      cutout; media alone is artwork opposite title/artist; agents alone is one status sprite
      opposite a count; both is artwork opposite one sprite. Shoulders went 128 → 92 and only
      the two-line media case is taller than the hardware. Measured: 184pt idle, 368pt active.
- [x] **The surface is pitch black.** The interior lift gradient and the rim hairline are
      deleted — they were the only two things drawing gradation, and gradation is what reveals
      the seam between the drawn surface and the physical cutout.
- [x] **The tab bar moved to the top left** and shrank (26 → 20pt, `micro` type). Centred, it
      sat directly under the camera housing, where the user could not see it.
- [x] **A paused player is not a live activity.** `NowPlayingStatus.isActive` only says a
      supported player is running with a track loaded, which stays true for hours after the
      music stops — so pausing left the shoulders out over the menu bar indefinitely. The rule
      now lives in `NotchSettings.showsMedia(_:)` (`isActive && isPlaying`), which is also what
      `FrameDump` seeds from, and it is a preference: "Hide when paused", on by default.
- [ ] Shelf: drag-drop file stash with AirDrop
- [x] **Volume/Brightness HUD replacement.** `SystemHUDMonitor` presents only key presses that
      `MediaKeyInterceptor` consumed and applied, so the readout always matches a level The
      Notch itself set. It no longer listens to CoreAudio or polls brightness: observing levels
      also observed keys Control Center handled, which drew both HUDs at once. The readout takes
      the collapsed shoulders and outranks both live activities.
- [x] **Suppressing the *native* HUD, which took two attempts.** `NativeOSDSuppressor`
      `SIGSTOP`s `OSDUIHelper` (`launchctl kill` fails under SIP with "Not privileged to signal
      service", and the helper is not running at login, so it is `kickstart`ed first). **On
      macOS 26 that suppresses nothing**: Control Center draws the banner now, and it cannot be
      stopped the same way because it also draws the whole menu bar. `MediaKeyInterceptor` takes
      the five HUD-drawing keys with a `CGEventTap` instead — nothing requests an OSD if nothing
      handles the key — and applies the level itself through CoreAudio and
      `DisplayServicesSetBrightness`. Needs Accessibility. Without it the keys stay with macOS,
      which draws its own HUD, and the notch draws none. `suppress()` is no longer called;
      `restore()` remains so a helper stopped by an old build resumes at launch.
- [x] **An update no longer silently loses the HUD.** An ad-hoc signed build is known to TCC by
      its code-directory hash, so every release lost the Accessibility grant while System
      Settings still showed it on — and the old once-per-machine prompt never asked again.
      `AccessibilityGrant` records which build held the grant and which was last asked: a build
      that lost a grant is asked once more, and settings shows "Re-add to Accessibility". Someone
      who never granted is still asked only once. A Developer ID signature would keep the grant
      across updates; releases without the signing secrets still ship ad-hoc.
- [ ] Webcam mirror
- [ ] Heart and repeat in the transport row are drawn but inert — they need real player
      commands or they should be removed rather than shipped as dead controls.

**Last touched:** 2026-10-01 — a build that lost its Accessibility grant to an update asks for it
again, and the HUD entries now describe interception-only presentation. Before that, 2026-08-17 —
a paused player no longer earns shoulders; the collapsed notch falls back to the bare hardware
cutout, or to the agent shoulders alone when an agent is live. Before that, 2026-08-16 — collapsed notch narrowed to *pictures only*: the
media shoulder trades title-over-artist for the playing waveform, shoulders drop 92 → 40pt for
live activities while the HUD keeps 92, and the silhouette no longer grows taller. The native
HUD is now suppressed by intercepting the keys rather than by suspending `OSDUIHelper`, which
does nothing on macOS 26. Shelf and webcam outstanding.

---

## Phase 7 — Ship `[~]`

- [x] Settings — a *surface* inside the notch, not a window. `NotchSettings` holds eleven
      preferences plus Restore Defaults; the gear in the expanded header opens it and pins the
      panel open while it is showing, and Quit lives beside it (there is no Dock icon and no
      menu bar item, so the app had no other way to be quit). Launch at login is a real
      `SMAppService` registration and reflects what the service reports, not what was clicked.
      No `Defaults`/`KeyboardShortcuts`/`LaunchAtLogin` dependency was needed — `UserDefaults`
      and `ServiceManagement` cover it. Keyboard shortcuts remain unbuilt.
- [ ] Onboarding: detect installed agent CLIs, offer one-click hook install
      — the *install* half now happens automatically at launch (`AppDelegate.installAgentHooks`,
      only for CLIs actually present). Nothing called `HookInstaller` before that, which is why
      the agent surfaces never lit up on a real machine. The onboarding UI and user consent
      before writing to their config are still missing.
- [x] Developer ID signing + notarization + Hardened Runtime
      — verified on 2026-10-02 with a `workflow_dispatch` build of 1.0.0-beta.6: notarisation
      Accepted, DMG stapled, Gatekeeper reports "Notarized Developer ID" for the DMG and the app,
      and the designated requirement is now identifier + team rather than a cdhash, so the
      Accessibility grant survives updates. The first submission took ~40 minutes in Apple's
      queue. `scripts/build-release.sh` signs with Hardened Runtime and a secure timestamp, then
      notarises and staples, whenever `CODESIGN_IDENTITY` and `NOTARY_KEYCHAIN_PROFILE` are set;
      without them it falls back to an ad-hoc signature so the pipeline still produces an
      installable build. The Release workflow feeds those from repository secrets
      (`MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGN_IDENTITY`, `NOTARY_KEY`,
      `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`), all set on 2026-10-02. The bundle is signed with
      `The Notch.entitlements` (`automation.apple-events` only): the hardened runtime refuses
      Apple Events from an app without it, which would break Now Playing and jump-back.
- [x] GitHub Releases — `.github/workflows/release.yml` builds a universal DMG on any `v*` tag
      and publishes it with generated notes and a SHA-256. `scripts/build-release.sh` archives
      `arm64 + x86_64`, replaces the checked-in arm64-only `notch-hook` with a `lipo`'d universal
      one, signs, and packages a DMG with an `/Applications` symlink. A `-` in the version marks
      the release as a prerelease. `workflow_dispatch` builds the same DMG as an artifact without
      publishing anything.
- [ ] Sparkle appcast (in-app updates)
- [x] Homebrew cask — `brew install --cask vallykrie/tap/the-notch`, from
      [Vallykrie/homebrew-tap](https://github.com/Vallykrie/homebrew-tap). Homebrew fetches over
      plain unauthenticated HTTP, so it cannot see this repository's release assets; the DMG is
      mirrored to the public [the-notch-releases](https://github.com/Vallykrie/the-notch-releases)
      repo, which holds binaries only and never any source. The release workflow mirrors the DMG
      and bumps the cask's `version`/`sha256` automatically once `RELEASE_REPO_TOKEN` is set.
      See [RELEASING.md](RELEASING.md).
- [ ] Licensing pass: end-user licence shipped with the build, every dependency confirmed
      permissive, `THIRD_PARTY_LICENSES` complete and bundled in the app
- [ ] README with demo GIF

> **Not shipping to the Mac App Store.** MAS requires App Sandbox, and this app cannot run
> sandboxed — the socket, agent-config merging, hook-binary install, AppleEvents jump-back and
> process-ancestry lookup are each blocked by it. Direct sale + Homebrew is the path, and is what
> comparable commercial apps in this category do. Full reasoning in ARCHITECTURE §4a.

**Last touched:** 2026-10-02 — releases are Developer ID signed, hardened, notarised and
stapled, with the Apple Events entitlement. Before that, 2026-08-17 — settings surface, Restore
Defaults, and Quit.

---

## Dependency order

```
Phase 0 ──> Phase 1 (shell/animation) ──┬──> Phase 3 (agent UI) ──> Phase 5 (usage UI)
            Phase 2 (bridge) ───────────┘
            Phase 2 ──> Phase 4 (jump-back)
            Phase 1 ──> Phase 6 (parity surfaces)
            all ──> Phase 7
```

Phases 1 and 2 are independent and are the two things to parallelise first.
