# Jump-back integrations

Jump-back is deliberately best-effort. Hook payloads are not guaranteed to contain terminal
metadata, so `JumpTarget` keeps every hint optional and `TerminalJumper` reports the precision it
actually achieved. An exact result means the selected tab/session matched an identifier; an
approximate result means the correct IDE and working-directory path were opened; application-only
means only the owning app could be activated.

## Implemented strategies

| Application | Precision | Required hint | Permission | Manual test |
| --- | --- | --- | --- | --- |
| iTerm2 | Exact window, tab, and split session | `ITERM_SESSION_ID`; `TERM_PROGRAM` or process ancestry helps routing | Automation access from The Notch to iTerm2 | Start two iTerm2 sessions, capture one session's `ITERM_SESSION_ID`, build and run The Notch, invoke jump-back for that target, accept the first TCC prompt, and confirm that exact session becomes selected. |
| Terminal.app | Exact tab when a supplied `tty` or tty-shaped `TERM_SESSION_ID` matches the tab's scripting `tty` | `tty` preferred; `TERM_SESSION_ID` is also compared when a hook supplies a tty value there | Automation access from The Notch to Terminal | Open multiple Terminal tabs, get the desired tab's `tty`, invoke jump-back, accept the first TCC prompt, and confirm that tab and its window become selected. |
| Visual Studio Code | Working-directory level (`approximate`) | `TERM_PROGRAM=vscode` or VS Code bundle ID from ancestry, plus `cwd` | None from Apple Events; macOS may ask to confirm opening the URL handler | From VS Code's integrated terminal, invoke a target with its PID and cwd; confirm `vscode://file/<path>` opens that folder/path. |
| Cursor | Working-directory level (`approximate`) | `TERM_PROGRAM=cursor` or Cursor bundle ID from ancestry, plus `cwd` | None from Apple Events | Repeat the VS Code test in Cursor and confirm `cursor://file/<path>` opens. |
| Zed | Working-directory level (`approximate`) | `TERM_PROGRAM=zed` or Zed bundle ID from ancestry, plus `cwd` | None from Apple Events | Repeat from Zed's terminal and confirm `zed://file/<path>` opens. |

AppleScript is executed asynchronously through `/usr/bin/osascript`, never on the main actor. Every
invocation has a deadline; a timed-out child is terminated and then killed before control returns.
Error `-1743` is surfaced as `automationPermissionDenied`, so UI can direct the user to **System
Settings → Privacy & Security → Automation**. Builds and automated tests must not invoke a strategy,
because the first real AppleEvent can show a TCC prompt.

## Process ancestry

`ProcessAncestryStrategy` walks `pid`/`ppid` using `proc_pidinfo` and obtains executable paths with
`proc_pidpath`. It derives the containing app bundle identifier without calling `ps` or another
process. This selects the applicable strategy when `TERM_PROGRAM` is absent. If no exact strategy
matches, a discovered running application can still be activated and is reported as
`applicationOnly`.

Terminal's scripting dictionary does not expose the UUID normally stored in its
`TERM_SESSION_ID` environment variable. A UUID alone therefore degrades to application activation;
hooks should include the tab's `tty` for an exact Terminal.app jump.

Manual ancestry test: run an agent inside the desired terminal or IDE, provide the agent PID in a
`JumpTarget`, and inspect the resolver result in the debugger. The owning bundle ID should be the
terminal/IDE bundle, even when no environment hints are supplied.

## Extension seam and unimplemented roadmap entries

`TerminalJumpStrategy` is the seam for another implementation: give it an identifier, decide whether
the target applies, and return an exact, approximate, no-match, or actionable failure result. Add it
to `TerminalJumper`'s ordered strategy list only after its targeting mechanism can be verified.

**Ghostty, WezTerm, Kitty, Warp, and Zellij are not implemented.** Bundle and environment names may
be recognized only to activate the owning application. Exact pane/tab support for these tools needs
verified OSC-2/title probing or a supported terminal API; no such behavior is claimed here. Zellij
also requires a multiplexer-aware pane strategy above the host terminal strategy.
