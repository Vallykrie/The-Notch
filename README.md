<p align="center">
  <img src="docs/images/icon.png" width="128" alt="The Notch app icon">
</p>

<h1 align="center">The Notch</h1>

<p align="center">
  Your MacBook's notch, turned into a live control surface for AI coding agents,<br>
  media and system controls.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
  <a href="https://github.com/sponsors/Vallykrie"><img src="https://img.shields.io/badge/sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors" alt="Sponsor"></a>
</p>

<p align="center">
  <img src="docs/images/mascot-states.gif" width="600" alt="The mascot acting out all nine agent states">
</p>

The Notch lives in the notch at the top of your screen. When a coding agent is working, a small
pixel mascot shows what it is doing. Hover over the notch to see every session, approve a
command without switching windows, answer an agent's question, and keep an eye on your music and
crypto prices.

- **See every agent at a glance.** Claude Code, Codex, Gemini CLI, Cursor, OpenCode, Antigravity
  and Kiro sessions show up automatically, including subagents.
- **Approve from the notch.** When an agent asks for permission, the notch lights up. Choose
  Allow Once, Always Allow or Deny without leaving what you are doing.
- **A mascot that is alive.** Each state has its own motion and colour. It startles when it needs
  you, celebrates when it is done, and falls asleep when it has been idle for a while.
- **Media, HUD and crypto.** Now playing with controls, a volume and brightness HUD that replaces
  the macOS one, and pinned Binance prices.
- **Works on any Mac.** Macs without a notch get a drawn notch in the same place.

## What it looks like

**Closed**, the notch shows the most important thing right now:

<p align="center"><img src="docs/images/collapsed.png" width="640" alt="The closed notch in five states"></p>

**Open** (hover over the notch), it shows the full panel:

| Agents and subagents | Approving a command |
| --- | --- |
| <img src="docs/images/agents.png" alt="Agent sessions with subagents"> | <img src="docs/images/approval.png" alt="Approval card with Deny, Always Allow and Allow Once"> |
| **Now playing** | **Crypto watchlist** |
| <img src="docs/images/media.png" alt="Media player"> | <img src="docs/images/crypto.png" alt="Crypto watchlist"> |

## Install

You need macOS 14 or later. The app is universal, so it runs on Apple silicon and Intel Macs.

### With Homebrew (recommended)

```bash
brew install --cask vallykrie/tap/the-notch
```

### Or download the DMG

1. Download the latest `The-Notch-<version>.dmg` from
   [the releases page](https://github.com/Vallykrie/The-Notch/releases).
2. Open it and drag **The Notch** into **Applications**.

### First launch

Open **The Notch** from Applications. It has no Dock icon; it appears in the notch at the top of
your screen.

If macOS says it cannot verify the developer, **right-click the app → Open → Open**. You only need
to do this once. Beta builds are not notarised yet, and this step stops being needed once they
are.

## Tutorial

### 1. Open the panel

Move your pointer onto the notch and the panel opens. Move away and it closes. It has three tabs
at the top: **Media**, **Agents** and **Crypto**. The gear on the right opens **Settings**.

### 2. Connect your coding agents

There is nothing to configure. The Notch looks for installed agents every 30 seconds and adds its
hook to each one it finds:

| Agent | Where the hook goes |
| --- | --- |
| Claude Code | `~/.claude/settings.json` |
| Codex | `~/.codex/hooks.json` (desktop and CLI activity are also read from local session files) |
| Gemini CLI | `~/.gemini/settings.json` |
| Cursor | `~/.cursor/hooks.json` |
| OpenCode | `~/.config/opencode/plugins/the-notch.js` |
| Antigravity | `~/.gemini/config/hooks.json` |
| Kiro | `~/.kiro/hooks/the-notch.json` |

Your existing hooks from other tools are kept. The Notch merges its entry in, never replaces the
file, and saves a backup next to it (`*.the-notch-backup.<date>`) before the first change.

**Start a new agent session** after installing, because agents only load hooks when a session
starts. To check the connection, go to **Settings → Connections…**. Each agent shows
*Receiving activity*, *Waiting for session*, *Not connected* or *Not detected*.

> **Codex:** to approve Codex commands from the notch, open `/hooks` in Codex and trust The
> Notch's hook. Codex asks again whenever a hook changes.

If the app is not running, agents behave exactly as before. The hook never blocks them.

### 3. Read the mascot

The closed notch shows the mascot for the agent you most recently gave work to, and how many
agents are running. The colour tells you the situation from across the room:

| Colour | Meaning |
| --- | --- |
| Blue / cyan | Working, running a tool, or waiting for your next prompt |
| Purple | Thinking or compacting its context |
| **Orange** | **Needs your approval.** The agent is stopped until you answer. |
| **Yellow** | **Asked you a question** |
| Green | Done |
| Dim green | Idle. It has been quiet for 5 minutes. |

When an agent is blocked on you, an orange ring also travels around the notch.

### 4. Approve commands and answer questions

When an agent asks for permission, open the notch. You will see the tool, the command and how
long it has been waiting:

- **Allow Once** runs this one command.
- **Always Allow** runs it and stops asking for this kind of command.
- **Deny** refuses it, and the agent carries on without it.

When an agent asks a question, pick an answer or type your own and press **Send**. If you would
rather reply in the terminal, choose **Ask in terminal**.

### 5. Keep the list tidy

Each row shows the project, what the agent is doing right now, elapsed time, tokens and cost.
Subagents appear indented under the session that started them.

- Hover over a row and click **–** to hide it. It comes back if that session does something new.
- **Clear Idle** removes every idle session at once.
- Sessions that go quiet become *Idle* after 5 minutes and leave the list after 15 minutes.

### 6. Media, volume and brightness

The **Media** tab shows what is playing, with play/pause, skip, a progress bar, and like, shuffle
and repeat. While music plays, the closed notch shows the artwork and a live waveform.

Turn on **Settings → Replace OS HUD** to see volume and brightness changes in the notch instead of
the macOS overlay. The app asks for the permission it needs to read the media keys.

### 7. Crypto

In the **Crypto** tab, use **Add pair** to search Binance Spot pairs (such as `BTC/USDT`) and
build a watchlist. Pin a pair to keep its live price in the closed notch. It uses Binance's
public feed, so there is no account or API key. See [Crypto feed details](docs/TRADING.md).

### 8. Settings

| Section | Options |
| --- | --- |
| Media | Show media, Hide when paused |
| Agents | Show agents, Attention ring, Sound cues, Keep done (how long finished sessions stay), Connections… |
| System | Replace OS HUD, HUD dwell (how long it stays on screen) |
| Behaviour | Expand on hover, Hover speed, Launch at login, Donate… |

**Quit** is in the top-right corner of Settings.

## Uninstall

```bash
brew uninstall --cask the-notch
```

Or quit the app and drag it from Applications to the Bin. The hooks it added to your agents are
harmless without the app: they fail open and let the agent carry on.

---

## For developers

### Build

Requires Xcode with the macOS 14 SDK. From the repository root, make a local unsigned Debug
build:

```bash
xcodebuild -project "The Notch.xcodeproj" \
  -scheme "The Notch" \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Releases are built by CI from `v*` tags; see [Releasing](docs/RELEASING.md).

### Tests and tools

| Command | What it checks |
| --- | --- |
| `bash tools/hook-harness/run-all.sh` | The hook bridge: happy path, allow, deny, timeout, concurrent sessions, malformed input. It never touches the real socket or agent config. Needs Go 1.22+. |
| `bash tools/session-tests/run.sh` | The session lifecycle (idle after 5 min, removed after 15 min, what is always kept) |
| `bash tools/trading-tests/run.sh` | The crypto store and watchlist migration |
| `NOTCH_FRAMES=<dir> "<app>/Contents/MacOS/The Notch"` | Renders every surface to PNGs. The screenshots above come from this. |
| `python3 scripts/render-app-icon.py` | Regenerates the app icon. See [App icon](docs/APP-ICON.md). |

### Documentation

- [Roadmap](docs/ROADMAP.md): phases and progress
- [Architecture](docs/ARCHITECTURE.md)
- [Hook protocol](tools/notch-hook/PROTOCOL.md)
- [Mascot design explorations](docs/design/): live HTML previews of the concepts behind the mascot

### Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). To report a
security problem privately, see [SECURITY.md](SECURITY.md).

## Support The Notch

The Notch is free and open source, and it will stay that way. If it saves you time, you can help
fund its development:

- **[Sponsor on GitHub](https://github.com/sponsors/Vallykrie)**, monthly or one-time
- Or use **Settings → Donate…** inside the app

Starring the repo and telling a friend helps too.

## License

The Notch is released under the [MIT License](LICENSE). Copyright (c) 2026 Vallykrie. Bundled
third-party components and their notices are listed in
[THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES).

The Notch is an independent project and is not affiliated with or endorsed by any other notch
utility or AI agent vendor. Claude, Codex, Gemini and other product names are trademarks of
their respective owners.
