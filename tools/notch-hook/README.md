# notch-hook

`notch-hook` is the small, dependency-free hook client used by The Notch. Agent CLIs invoke it with hook JSON on stdin; it wraps that JSON in The Notch's newline-delimited protocol and sends it to `/tmp/the-notch.sock`. Set `THE_NOTCH_SOCKET` to use another Unix socket.

```sh
notch-hook --source claude --event PostToolUse < hook.json
notch-hook --source codex < hook-with-event-field.json
```

When `--event` is omitted, the client reads `hook_event_name` or `event` from the payload. Non-permission events are sent with short socket deadlines and produce no output. `PermissionRequest` waits for the server response for the envelope's timeout (7200 seconds by default), then writes:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"Approved in The Notch"}}}
```

Server decisions `allow` and `allow_always` currently map to `allow`, `deny` maps to `deny`, and `defer` produces no output so the CLI can use its normal interactive prompt. This stdout mapping is the integration point most likely to require adjustment as Claude Code or Codex hook schemas change between CLI versions.

Every failure is intentionally fail-open: malformed input, unavailable sockets, refused connections, write errors, invalid replies, and response timeouts all exit successfully without output. The client must never prevent the calling agent from continuing.

## Build

Run `./build.sh` to create static, CGO-disabled binaries in `dist/` for Darwin, Linux, and FreeBSD on arm64 and amd64. The remote binaries are for agents running over SSH; their `THE_NOTCH_SOCKET` must name a Unix socket reachable in that environment (for example, one forwarded to the Mac-side server).
