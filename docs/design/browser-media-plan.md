# Browser media support — research and plan

Goal: the media surface shows and controls playback from **any** source, including Spotify Web,
YouTube and YouTube Music in a browser, not only the Spotify and Music desktop apps.

## 1. Research findings

### Why browsers are invisible today
`NowPlayingMonitor` sends AppleScript to `com.spotify.client` and `com.apple.Music` only. Browsers
are never asked. They *do* publish tab playback to the system Now Playing service through the web
Media Session API, so the data exists. It just lives behind the private MediaRemote framework.

### MediaRemote access on current macOS
Since macOS 15.4, `mediaremoted` only answers processes with a `com.apple.*` identity. A third-party
app that calls MediaRemote gets `nil`. Two Apple-signed binaries still have access and can be used as
a host.

Tested on this machine, **macOS 27.0.1 (26A434)**, on 2026-10-15:

| Route | Metadata | Source bundle id | Artwork | Controls | Latency |
|---|---|---|---|---|---|
| `/usr/bin/perl` + `mediaremote-adapter` (`get`) | ✅ | ✅ `com.spotify.client` | ✅ 130 KB JPEG | ✅ (`send`, `seek`) | ~25 ms per `get`; `stream` pushes changes |
| `/usr/bin/osascript -l JavaScript` + `MRNowPlayingRequest` | ✅ | ✅ (via `localNowPlayingPlayerPath`) | ❌ (async callback never delivered in JXA) | ✅ `MRMediaRemoteSendCommand` returned true | ~45 ms per call, polling only |

The JXA route matches the probe used by MaxBroda/roger issue #27.

### `ungive/mediaremote-adapter`
- **Licence:** BSD 3-Clause, © 2025 Jonas van den Berg and contributors. This is MIT-compatible, so
  it is allowed under our ground rules with a `THIRD_PARTY_LICENSES` entry.
- **How it works:** a small ObjC framework that `/usr/bin/perl` loads through `DynaLoader`. Perl is
  Apple-signed and entitled, so MediaRemote answers it. Our app never links the framework.
- **CLI:** `get`, `stream` (diffed JSON lines, `--debounce`, `--no-diff`), `send <0–13>`,
  `seek <µs>`, `shuffle`, `repeat`, `speed`, and `test` (exit 0 = usable).
- **Payload:** `bundleIdentifier`, `playing`, `title` (always present), plus `artist`, `album`,
  `duration`, `elapsedTime`, `timestamp`, `playbackRate`, `artworkData` (base64),
  `artworkMimeType`, `contentItemIdentifier` and more.
- **Size:** about 2.9k lines (ObjC plus the Perl script). Built with CMake; it builds cleanly here
  for arm64 and x86_64.

### Risks
1. **Private framework.** Any macOS update can close the `com.apple.*` loophole. Use the adapter's
   `test` gate and keep AppleScript as the fallback, so the feature degrades instead of breaking.
2. **System Perl may go away.** Apple has warned since 2019 (Catalina) that scripting runtimes will
   not ship by default "in a future release". Perl is still present on 27.0.1. Mitigation: the JXA
   route covers metadata and controls without Perl. It loses artwork, so add the Spotify artwork URL
   or the Music AppleScript artwork as the backup.
3. **Single item.** System Now Playing exposes only the app that currently holds media controls. With
   Spotify and YouTube both open, the most recent player wins. That matches Control Centre, which is
   acceptable.
4. **Browser metadata quality.** YouTube titles look like "Artist - Song (Official Video)" and the
   artist is the channel name. YouTube Music and Spotify Web give clean metadata.

## 2. Recommendation

**Vendor `mediaremote-adapter` and make MediaRemote the primary source.** Keep the current AppleScript
path as an automatic fallback. Reasons:

- One source covers every browser (Safari, Chrome, Arc, Edge, Firefox) and every other app with no
  per-browser code.
- **No Automation prompts.** Today the first use asks for Apple Events permission for Spotify and
  Music. The adapter needs no TCC permission at all.
- Push updates (`stream`) replace the 2 s `osascript` poll. That gives faster track changes and less
  work while idle.
- Artwork arrives inline. The Spotify CDN fetch, which is the app's only network call, becomes a
  fallback-only path.
- Writing our own equivalent would be original code but would mean re-solving its edge cases
  (artwork flicker, diffing, TIDAL quirks). Vendoring a pinned BSD-3 snapshot is cheaper and
  permitted.

Rejected:
- **AppleScript `execute javascript` into browser tabs.** Needs a per-browser developer toggle,
  doesn't work for Firefox, means hunting for the right tab, and adds another Automation prompt.
- **Browser extension.** Means building and shipping an extension per store. Far too much for this.
- **XPC helper (the ARCHITECTURE note).** Our own helper is not `com.apple.*`, so it gets the same
  denial. It doesn't solve the problem.

## 3. Implementation plan

### Phase 0 — Spike (½ day, throwaway branch)
- [x] Vendor the adapter source at a pinned commit under `Vendor/MediaRemoteAdapter/`.
- [x] *(Done as a Run Script phase; M1 moves it to a framework target.)* Add an Xcode **framework target** that compiles it as a universal binary. Copy the framework and
      `mediaremote-adapter.pl` into `Contents/Resources/MediaRemoteAdapter/` as a resource, not as
      a linked or embedded framework.
- [x] From inside the built app, run `test` and log `stream` output.
- [x] *(Chrome, Safari, Brave done; Spotify Web, Arc, Firefox open.)* Verify sources: Safari, Chrome, Arc, Firefox × YouTube, YouTube Music, Spotify Web. Also check
      the reported `bundleIdentifier` for each, and whether play/pause, next, previous and seek work.
- [ ] Verify a **Developer ID–signed, notarised** build still loads (perl has to accept our signed
      framework).
- Exit criterion: browsers appear with artwork, and controls work in a signed build.

#### Phase 0 results (2026-10-15, macOS 27.0.1, branch `spike/browser-media`)

What was built:
- `Vendor/MediaRemoteAdapter/` holds upstream `797729d` unmodified (see `VENDORED.md`).
- `tools/build-mediaremote-adapter.sh` runs as an Xcode Run Script phase, compiling with clang
  (no CMake needed). It produces `Contents/Frameworks/MediaRemoteAdapter.framework`,
  `Contents/Helpers/MediaRemoteAdapterTestClient` and `Contents/Resources/mediaremote-adapter.pl`.
- `scripts/build-release.sh` signs the adapter framework and test client before the app.
- `Debug/MediaRemoteSpike.swift` is a DEBUG-only probe. `NOTCH_MR_SPIKE=<seconds>` runs `test`,
  then `stream`, printing one line per update, and quits.

| Check | Result |
|---|---|
| `test` launched by the app | ✅ exit 0, ~70 ms |
| Chrome · YouTube | ✅ `com.google.Chrome`; title, channel as artist, duration, artwork (~9 KB) |
| Safari · YouTube Music | ✅ clean title/artist, artwork ~350 KB. **Reported as `com.apple.WebKit.GPU`**; the real app is in `parentApplicationBundleIdentifier` = `com.apple.Safari` |
| Brave · YouTube | ✅ `com.brave.Browser` |
| Spotify desktop | ✅ (seen at start, with artwork) |
| Spotify Web | ⚠️ not verified: it needs a click and a login, so it wouldn't autoplay |
| Firefox, Arc, Edge | ⚠️ not installed here |
| Controls: play, pause, next, seek | ✅ on Chrome (pause, play, seek to 60 s) and on YouTube Music in Safari (next went to the following track) |
| Idle cost of `stream` | ✅ ~21 MB RSS, 0.02 s CPU over 30 s |
| Release archive | ✅ universal (x86_64 + arm64); the Intel slice loads under Rosetta |
| Developer ID signing | ⏳ codesign blocked on a keychain access prompt; needs the maintainer at the keyboard |
| Notarisation | ⏳ no local notary profile; verify on the first CI release from this branch |

Findings that change the plan:
1. **Use `parentApplicationBundleIdentifier` when it's present.** WebKit plays media in a helper
   process, so Safari (and probably other WebKit apps) shows up as `com.apple.WebKit.GPU`.
2. **YouTube ads are now-playing items.** They have their own title, artist (the advertiser),
   duration and artwork, and media keys can't skip them. Phase 2 should accept that ads show, and
   lyrics must not search for them. There's no reliable ad flag in the payload; the
   `contentItemIdentifier` changes per ad.
3. **Artwork arrives in a second update.** The first update has metadata only, then
   `artworkData` follows. Keep the previous artwork until the new data lands, or
   cross-fade from a placeholder. Never flash empty.
4. **A blank update appears between items** (every field missing) when the source changes. The
   status layer should debounce, about 300 ms, before going inactive, or the notch collapses and
   reopens on every track change.
5. **`mediaType` is missing for browser items**, so it can't decide whether lyrics apply.
6. **Xcode's user-script sandbox blocks writing a framework bundle** from a Run Script phase. The
   spike turned `ENABLE_USER_SCRIPT_SANDBOXING` off for the app target, where this is the only
   script phase. Phase 1 should replace it with a real framework target plus a Copy Files phase,
   so sandboxing can go back on.
7. **`test` spawns the test client**, which briefly registers a fake now-playing item. Upstream warns
   it can interfere with other apps. Run it once per launch, before streaming starts, never per
   poll. A cheaper gate is worth checking: does `get` exit non-zero when it isn't entitled?

### Roadmap after the spike

Three PRs, each shippable on its own. The ROADMAP checkbox lands in the same commit as the code.
Docs (ARCHITECTURE, ROADMAP, `THIRD_PARTY_LICENSES`) ship with the PR they describe, not as a
separate phase.

| PR | Outcome for the user | Size (new + changed lines) |
|---|---|---|
| **M1 — Browser playback in the notch** | YouTube, YouTube Music, Spotify Web and every other player show in the notch with artwork and working controls. No more Automation prompts. | ~900 |
| **M2 — Sources, settings, badge** | Badge shows the real app (Chrome, Safari…). Settings has per-source toggles. Ads and 16:9 thumbnails look right. | ~400 |
| **M3 — Polish and resilience** | Lyrics work for YouTube titles. The helper sleeps when nothing plays. A Perl-free fallback exists. | ~300 |

#### M1 — Browser playback in the notch

Build
- [x] Turn `ENABLE_USER_SCRIPT_SANDBOXING` back on. **Changed from the plan:** the Run Script
      phase stayed, because a framework target meant hand-editing much more of the project
      file. It works inside the sandbox once every output file is declared, `rm -rf` is gone,
      and it stops calling `codesign`. The linker ad-hoc signs each binary, which a development
      build needs; `scripts/build-release.sh` signs both with the Developer ID.
- [x] Delete `Debug/MediaRemoteSpike.swift` and its `AppDelegate` hook.

Adapter process — new `Surfaces/System/NowPlaying/MediaRemoteAdapter.swift`
- [x] Locate the script, framework and test client in the bundle. If any is missing, the adapter
      is unavailable.
- [x] `probe()`: run `test` once per launch, off the main actor, with a 3 s timeout. Not exit 0
      → unavailable for this run.
- [x] `stream`: one long-lived `/usr/bin/perl … stream --debounce=100` process. Split stdout into
      lines and hand them to the parser. Log stderr only.
- [x] Restart after an unexpected exit with backoff (1 s, 5 s, 30 s), giving up after 3. On give-up
      the monitor falls back to AppleScript.
- [x] `send(command)` / `seek(seconds)`: one-shot processes, `send 2` toggles play/pause, 4 is next,
      5 is previous, `seek <µs>`.
- [x] Stop on sleep and when the feature is off; restart on wake.

Payload → status — new `Surfaces/System/NowPlaying/AdapterPayload.swift` (pure, unit-tested)
- [x] Merge diffs into a snapshot (`diff: true`, with `null` = remove; `diff: false` = replace).
- [x] Source app = `parentApplicationBundleIdentifier ?? bundleIdentifier`. This is the Safari
      `com.apple.WebKit.GPU` fix.
- [x] Map to `NowPlayingStatus`: title, artist, playing, elapsed, timestamp, rate, duration.
      Artwork is decoded from base64 once per `contentItemIdentifier`, capped at 4 MB.
- [x] **Keep the previous artwork** until the new `artworkData` arrives for the same item.

Model — `NowPlayingStatus.swift`
- [x] `Player` becomes `spotify | music | app(bundleIdentifier:)`. The two existing cases keep the
      AppleScript path and the UI working unchanged. Everything else is `app`. M2 gives it a name
      and icon; until then the badge says "Now Playing".

Monitor — `NowPlayingMonitor.swift`
- [x] Choose a backend at launch: the adapter if `probe()` passes, otherwise the existing
      AppleScript polling. The AppleScript code is kept as-is behind the same published `status`.
- [x] **Blank-gap debounce.** An empty snapshot only publishes `.inactive` after 300 ms, so the
      notch doesn't collapse between tracks or between an ad and the video.
- [x] **Live elapsed time.** `stream` doesn't tick. While playing, a 1 s timer republishes
      `elapsed + (now − timestamp) × rate`, clamped to the duration. The views already render
      `status.progress`, and `LyricsController` already anchors its own clock, so **no view
      changes are needed**.
- [x] Commands go to the active backend. Keep the optimistic UI and generation guard. The adapter
      path needs no `deniedPlayers` logic because it uses no Automation permission.
- [x] Respect the current `MediaPlayers` setting: with Music only or Spotify only selected, `app`
      sources are hidden. "All" includes browsers. M2 replaces the setting.

Release and docs
- [x] `scripts/build-release.sh` already signs the adapter (done in the spike).
- [ ] Verify the first Developer ID–signed, notarised CI build.
- [x] `THIRD_PARTY_LICENSES` entry, plus `Resources/Licenses/MediaRemoteAdapter-LICENSE.txt`.
- [x] ARCHITECTURE §2: replace the "XPC helper" note with the adapter design and its fallback.
- [x] ROADMAP: amend the "MediaRemote was rejected" entry and tick M1.

Tests — new `tools/media-tests/` (same `swiftc` pattern as `hud-tests`)
- [x] Parser fixtures with placeholder titles: full snapshot, diff, `null` removal, artwork-only
      update, the Safari parent id, and a blank gap.
- [x] Elapsed extrapolation: playing, paused (rate 0), clamped at the duration.
- [x] Tests never spawn `/usr/bin/perl`. **Changed from the plan:** no fake process runner. The
      process layer (`MediaRemoteAdapter`) is thin and was verified against real players with
      `--media-diagnostics 60 --exercise`, a headless run of the real monitor added in
      `Debug/MediaDiagnostics.swift`.

Manual check, done 2026-10-15 with `--media-diagnostics`: Brave (YouTube) → Safari (YouTube
Music) switch with no empty flash, Safari named correctly, artwork held across the change,
play/pause/seek through the monitor, no perl left running after quit. Not yet seen in the real
notch UI, Spotify Web, or Music via MediaRemote.

#### M2 — Sources, settings, badge
- [ ] `MediaSourceKind`: map bundle ids to `.music`, `.spotify`, `.browser` (Safari, Chrome, Arc,
      Edge, Brave, Firefox, Opera, Vivaldi, Zen, Orion, Dia) or `.other`.
- [ ] Settings: replace the All / Music / Spotify picker with toggles. Music, Spotify and Browsers
      default to on; Other apps defaults to off. Migrate `NotchMediaPlayers`: `all` → all on,
      `music` → Music only, `spotify` → Spotify only. A disallowed source shows as inactive.
- [ ] Badge and "Open" button: the app's localised name and icon via `NSWorkspace`. "Open"
      activates the app; a browser tab can't be targeted.
- [ ] Artwork: aspect-fill crop for 16:9 thumbnails in the square tile and the collapsed view.
- [ ] Ads: no special casing beyond "lyrics never search an item without a matching duration".
      Document that ads show, like they do in Control Centre.
- [ ] Update ROADMAP and settings tests.

#### M3 — Polish and resilience
- [x] Lyrics: before the LRCLIB lookup, strip "(Official Video)", "[MV]", "(Lyrics)", "4K
      Remaster" and similar. Split "Artist - Title" when the artist is a channel, and drop
      " - Topic". Unit-tested. **Pulled into M1** after testing found wrong lyrics: the old
      fallback cut `Queen - All Dead, All Dead - …` at the first dash and searched for a song
      called "Queen", and a result of the wrong length was used when nothing matched.
      `LyricsProvider.searchQueries` now removes a leading artist first, and a known track
      length with no result within 10 s means no lyrics.
- [ ] Idle: stop `stream` after 10 minutes with no item and resume on the next media key or panel
      open. Needs measuring first; the idle cost is already low (~21 MB, ~0 CPU).
- [ ] Orphaned stream after a force-quit: if the app is killed with SIGKILL, its `perl stream`
      child stays alive (idle, ~21 MB) until the next Now Playing change, then exits on SIGPIPE.
      Measured 2026-10-15. Possible fixes: kill a stale stream at launch (record its pid), or
      have the script watch its parent.
- [ ] Optional: JXA `MRNowPlayingRequest` fallback for when Perl is gone (metadata and controls,
      no artwork).
- [ ] Update ROADMAP.

### Effort, honestly
The "days" above were for a person working focused. What drives the size is mostly M1's refactor
of `NowPlayingMonitor` (661 lines) behind two backends without breaking the current behaviour.
The adapter and parser are small and testable. M1 is the only risky PR; M2 and M3 are routine.
Your time: a review per PR, plus a manual run with the browsers you actually use.

## Sources
- https://github.com/ungive/mediaremote-adapter (README, LICENSE)
- https://github.com/MaxBroda/roger/issues/27 (JXA probe; unsourced claim about Perl removal)
- https://tidbits.com/2019/06/25/apple-to-deprecate-scripting-languages-in-future-versions-of-macos/
- https://github.com/aviwad/LyricFever/issues/94 (MediaRemote returning nil after 15.4)
