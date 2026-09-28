# The Notch hook protocol

This document is the maintained contract between `notch-hook` and The Notch. It is separate from the hook-output contracts of Claude Code and Codex.

## Transport and framing

The client connects to the Unix-domain socket `/tmp/the-notch.sock`. `THE_NOTCH_SOCKET`, when non-empty, replaces that default. Each direction uses newline-delimited JSON: one complete, compact JSON object followed by `\n`. A peer must not split one logical object across multiple lines.

The client has a 250 ms connection deadline and a 500 ms write deadline. It writes one request per connection. Telemetry events return immediately after the write and do not read a response. A `PermissionRequest` keeps the connection open for one response line.

## Client request

```json
{"id":"4bb33d4a-3287-4b58-a1cf-fbb7604dba8e","event_name":"PreToolUse","source":"claude","cwd":"/work/project","thread_name":"session-42","timeout":5,"payload":{"hook_event_name":"PreToolUse","session_id":"session-42","cwd":"/work/project"}}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Fresh UUID v4 generated for this request. |
| `event_name` | string | Supported hook event, taken from `--event` or inferred from payload `hook_event_name`, then `event`. |
| `source` | string | Required `--source` value identifying the agent CLI. |
| `cwd` | string | Payload `cwd`, or the hook process working directory when absent. |
| `thread_name` | string, optional | First non-empty payload value among `thread_name`, `session_id`, and `conversation_id`. Omitted when none exists. |
| `timeout` | integer | Lifetime/decision budget in seconds: 5 for telemetry, 7200 for permission requests. |
| `payload` | JSON value | The original valid JSON read from stdin, preserved as JSON rather than quoted text. |

Supported `event_name` values are:

- `SessionStart`
- `SessionEnd`
- `UserPromptSubmit`
- `PreToolUse`
- `PostToolUse`
- `Notification`
- `Stop`
- `SubagentStart`
- `SubagentStop`
- `PostToolUseFailure`
- `PreCompact`
- `PostCompact`
- `PermissionRequest`

## Server response

Only `PermissionRequest` consumes a response:

```json
{"id":"4bb33d4a-3287-4b58-a1cf-fbb7604dba8e","decision":"deny","reason":"Command is outside policy"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Must exactly match the request `id`. |
| `decision` | string | `allow`, `deny`, `allow_always`, or `defer`. |
| `reason` | string, optional | Human-readable explanation passed toward the invoking CLI when output is produced. |
| `updated_input` | JSON object, optional | The tool input to run *instead of* the proposed one. The Notch sets it when the user answered a question in the panel rather than approving a call — the same `tool_input`, with the tool's `answers` map filled in. Ignored unless it parses as a JSON object, and never forwarded for `--source codex` (see below). |

`allow_always` has the same one-shot hook stdout as `allow`; persistence is a server/application concern. `defer` produces no hook stdout, leaving the invoking CLI to prompt normally.

## Timeouts and fail-open behavior

The request `timeout` is expressed in seconds. It is 5 for every telemetry event and 7200 for `PermissionRequest`. For a permission request, the client also sets its response read deadline to 7200 seconds. The receiver should regard the value as the event freshness or decision budget; it is not a request for an arbitrary server-selected timeout.

The hook deliberately fails open so an unavailable integration cannot block the agent. Each of these cases exits 0 and writes nothing to stdout:

- unknown flags, flag parse errors, or missing `--source`;
- malformed, oversized, unreadable, or non-JSON stdin;
- an unsupported or missing event name;
- an unreachable socket or a failed/timed-out write;
- an invalid response, mismatched response `id`, unknown decision, or `defer`;
- response EOF or the 7200-second permission read timeout.

This behavior follows the implementation in `tools/notch-hook/main.go`. In particular, the program does not propagate an error exit code to the invoking CLI.

## Permission-decision stdout and CLI compatibility

### Current `notch-hook` output

The client selects its permission stdout contract from the `--source` value. For `claude` and any other non-empty source except `codex`, it preserves the existing top-level output:

```json
{"permissionDecision":"allow"}
```

When the server supplies `updated_input`, the Claude/default object carries it as `updatedInput` beside the decision:

```json
{"permissionDecision":"allow","permissionDecisionReason":"Answered from The Notch: Yes","updatedInput":{"questions":[{"question":"Ship it?"}],"answers":{"Ship it?":"Yes"}}}
```

`updatedInput` is the field Claude Code documents for a hook that supplies what an interactive prompt would have collected; the installed 2.1.227 binary carries both that field and the log line `Hook satisfied user interaction for <tool> via updatedInput, bypassing permission prompt`. **UNVERIFIED** against an interactive session — a print-mode run never reaches a `PermissionRequest` hook, so this could not be exercised headlessly. The failure mode is benign: a CLI that ignores the field sees a plain `allow` and collects the answer in the terminal, exactly as it did before.

For `codex`, it emits the event-specific shape verified against the locally installed Codex version:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

The mappings are:

| Wire decision | Claude and default stdout | Codex stdout |
| --- | --- | --- |
| `allow` | `permissionDecision: "allow"` | `decision.behavior: "allow"` |
| `allow_always` | `permissionDecision: "allow"` | `decision.behavior: "allow"` |
| `deny` | `permissionDecision: "deny"` | `decision.behavior: "deny"` |
| `defer` | no output | no output |

Each actionable result is one compact JSON object followed by a newline. When the server supplies a non-empty reason, the Claude/default object includes `permissionDecisionReason`, while the Codex `decision` object includes `message`. The Codex object never includes `interrupt`, `updatedInput`, `updatedPermissions`, `continue`, `stopReason`, or `suppressOutput`.

### Claude Code

**UNVERIFIED:** the exact `PermissionRequest` stdout contract for the locally installed Claude Code 2.1.224 could not be established without ambiguity.

Local evidence:

- `claude --help` establishes CLI and hook-related options but does not document the `PermissionRequest` output schema.
- `strings ~/.local/share/claude/versions/2.1.224 | rg -n -C 40 'permissionDecisionReason'` exposes embedded help that requires `hookSpecificOutput.hookEventName` for event-specific output and lists `permissionDecision` / `permissionDecisionReason`, but labels those fields “PreToolUse only.” It therefore does not establish their `PermissionRequest` shape.
- `~/.claude/settings.json` contains configured `PermissionRequest` hooks, but configuration does not establish accepted stdout.

Accordingly, the preserved top-level `permissionDecision` object must not be assumed Claude-compatible from available local evidence.

### Codex

The locally installed Codex binary contains a more specific schema. `codex --help` does not document it, but this local command exposes the embedded `permission-request.command.output` schema:

```sh
strings ~/.codex/packages/standalone/current/bin/codex | sed -n '51690,51790p'
```

The embedded `PermissionRequestHookSpecificOutputWire` and `PermissionRequestDecisionWire` schemas accept an object shaped like:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"Approved by The Notch"}}}
```

`PermissionRequestDecisionWire` rejects additional properties, so `updated_input` is never forwarded on this path: an answered question sent to Codex would invalidate the whole object and take the decision down with it. `PermissionRequestBehaviorWire` restricts `behavior` to `allow` or `deny`; `message` is optional. `PermissionRequestDecisionWire` rejects additional properties, and the same installed binary includes runtime errors rejecting unsupported `updatedInput`, `updatedPermissions`, `interrupt: true`, `continue: false`, `stopReason`, and `suppressOutput`. `notch-hook` now emits this shape only for `--source codex`, maps `allow_always` to one-shot `allow`, includes a non-empty server reason as `message`, and emits nothing for `defer`. This is verified against this installed Codex version only; any broader claim about other versions is **UNVERIFIED**.
