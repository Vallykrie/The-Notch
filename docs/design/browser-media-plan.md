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
- [ ] Vendor the adapter source at a pinned commit under `Vendor/MediaRemoteAdapter/`.
- [ ] Add an Xcode **framework target** that compiles it as a universal binary. Copy the framework and
      `mediaremote-adapter.pl` into `Contents/Resources/MediaRemoteAdapter/` as a resource, not as
      a linked or embedded framework.
- [ ] From inside the built app, run `test` and log `stream` output.
- [ ] Verify sources: Safari, Chrome, Arc, Firefox × YouTube, YouTube Music, Spotify Web. Also check
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

### Phase 1 — Adapter source behind a fallback
- [ ] `MediaSource` protocol: `start`, `stop`, `send(TransportCommand)`, and a status stream.
      Move the current AppleScript logic into `AppleScriptMediaSource` unchanged.
- [ ] `MediaRemoteAdapterSource`:
  - Run `test` once per launch, off the main actor, with a timeout. Fail → use AppleScript for this
    run.
  - Keep one long-lived `Process`: `/usr/bin/perl <pl> <framework> stream --debounce=100`. Read
    stdout line by line, apply diffs to a snapshot dictionary, and map it to `NowPlayingStatus`.
  - Commands run as one-shot `send <n>` or `seek <µs>` processes. Keep the existing optimistic UI
    and generation guard.
  - Restart after an unexpected exit with backoff, capped. A non-zero exit from `test` disables the
    source for the session, as upstream asks.
  - Stop the process on sleep, when the feature is switched off, and when the panel is suspended.
    Restart on wake.
  - Fail open: stderr is logged, never surfaced, and any parse error yields `.inactive`.
- [ ] **Live elapsed time.** `stream` doesn't tick, so derive the position as
      `elapsedTime + (now − timestamp) × playbackRate`. Drive the scrubber from a `TimelineView` or
      the existing clock, not from repeated polling.
- [ ] Artwork: decode base64 once per `contentItemIdentifier`, and keep the 4 MB cap from
      `maximumArtworkByteCount`.

### Phase 2 — Model, settings, UI
- [ ] Replace `NowPlayingStatus.Player` (`spotify | music`) with a `MediaSourceApp` value: bundle
      id, display name, and kind (`.music`, `.spotify`, `.browser`, `.other`). Known browser bundle
      ids map to `.browser`.
- [ ] Settings: replace the All / Music / Spotify picker with source toggles. Proposed toggles:
      Music, Spotify and Browsers default to on; Other apps defaults to off. Migrate the old
      `NotchMediaPlayers` value. A disallowed source shows as inactive; it doesn't fall through.
- [ ] Source badge and "Open" button: use the app's real name and icon from `NSWorkspace` for the
      bundle id. Activate the browser; a specific tab can't be targeted, which is fine.
- [ ] Artwork view: YouTube thumbnails are 16:9, so aspect-fill crop to the square tile.

### Phase 3 — Polish
- [ ] Lyrics: normalise browser titles before the LRCLIB lookup. Strip "(Official Video)", "[MV]",
      "(Lyrics)" and similar, split "Artist - Title" when the artist is a channel, and drop
      " - Topic". Skip lyrics when `mediaType` is video and nothing matches.
- [ ] Measure the idle cost of the perl process (RSS and CPU) over an hour of playback. Also measure
      it with nothing playing, and consider stopping `stream` after N minutes with no now-playing
      item.
- [ ] Optional secondary fallback: the JXA `MRNowPlayingRequest` probe, for when Perl is gone. It
      gives metadata and controls without artwork.

### Phase 4 — Docs and housekeeping
- [ ] `THIRD_PARTY_LICENSES` entry (version or commit, copyright, BSD-3, source, location in the
      bundle). Copy the licence text into `Resources/Licenses/`.
- [ ] ARCHITECTURE §2: replace the "XPC helper" note with the perl-adapter design and its fallback.
- [ ] ROADMAP: amend the "MediaRemote was rejected" entry and add checkboxes for each phase above.

### Tests
- Parser tests against recorded `stream` lines: full snapshot, diffs, a `null` removal, and an
  artwork-only update. Fixtures use placeholder titles.
- Elapsed-time extrapolation, including paused playback (rate 0) and clamping at the duration.
- Source mapping and settings migration.
- Inject a fake process runner. Unit tests never spawn `/usr/bin/perl`.

### Estimate
Spike ½ day · Phase 1 1½–2 days · Phase 2 1 day · Phase 3 ½–1 day · docs ½ day. About 4–5 days.

## Sources
- https://github.com/ungive/mediaremote-adapter (README, LICENSE)
- https://github.com/MaxBroda/roger/issues/27 (JXA probe; unsourced claim about Perl removal)
- https://tidbits.com/2019/06/25/apple-to-deprecate-scripting-languages-in-future-versions-of-macos/
- https://github.com/aviwad/LyricFever/issues/94 (MediaRemote returning nil after 15.4)
