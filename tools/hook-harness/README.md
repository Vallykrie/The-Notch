# Hook harness

The hook harness exercises `notch-hook` against a fake Unix-socket server. It verifies process behavior and compares the received envelopes with scenario expectations, without starting The Notch or touching the real app socket and agent configuration.

## Run the suite

From the project root:

```sh
bash tools/hook-harness/run-all.sh
```

The runner builds `notch-hook` once, creates a separate short-lived socket and report for each scenario, and gives every driven hook process an isolated temporary `HOME`, `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, and `XDG_CONFIG_HOME`. It never uses `/tmp/the-notch.sock`. A hard watchdog bounds each scenario. The final table reports `PASS` or `FAIL`; any failure makes the script exit non-zero and prints that scenario's drive and server logs.

## Scenarios

| Scenario | What it proves |
| --- | --- |
| `happy-path` | A single session sends `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop` in order with telemetry TTL 5. |
| `approval-allow` | A `PermissionRequest` reaches the server, carries TTL 7200, and an `allow` reply becomes the client's current allow stdout. |
| `approval-deny` | The corresponding `deny` reply becomes the client's current deny stdout. |
| `approval-timeout` | A no-reply server closes at its short test lifetime; the waiting permission client fails open with exit 0 and empty stdout before the step timeout. This bounds the test without waiting for the production 7200-second read deadline. |
| `concurrent` | Three session identities in distinct working directories remain distinct while their deterministic, sequential harness steps are interleaved. |
| `malformed` | Junk, broken JSON lines, and a valid JSON payload with an unsupported event all exit 0 silently and send no envelope. |

The `concurrent` scenario is an ordering/isolation test, not a claim that `drive` launches its steps simultaneously.

## Run one scenario manually

This example stays on disposable paths and builds both binaries into the same temporary directory:

```sh
case_dir="$(mktemp -d /tmp/notch-hook-manual.XXXXXX)"
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$case_dir"' EXIT

go build -C tools/notch-hook -o "$case_dir/notch-hook" .
go build -C tools/hook-harness -o "$case_dir/hook-harness" .

"$case_dir/hook-harness" serve \
  --socket "$case_dir/hook.sock" \
  --report "$case_dir/report.jsonl" \
  --decision allow &
server_pid=$!

while [[ ! -S "$case_dir/hook.sock" ]]; do sleep 0.02; done

"$case_dir/hook-harness" drive \
  --scenario approval-allow \
  --socket "$case_dir/hook.sock" \
  --report "$case_dir/report.jsonl" \
  --hook-binary "$case_dir/notch-hook"
```

`serve` writes each valid request as JSONL when `--report` is set. Permission replies can use `--decision allow`, `deny`, `allow_always`, or `defer`, optionally with `--reason`; `--no-reply` accepts a permission request without responding.

## Add a scenario

Create `tools/hook-harness/scenarios/<name>.json`. Scenario names passed without a path resolve in that directory. Only the keys below are accepted because decoding rejects unknown fields:

```json
{
  "name": "example",
  "steps": [
    {
      "label": "session start",
      "source": "claude",
      "event": "SessionStart",
      "input": { "hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/tmp/example" },
      "process_timeout": "3s",
      "expect": { "exit_code": 0, "timed_out": false, "stdout": "" },
      "envelope": {
        "event_name": "SessionStart",
        "source": "claude",
        "cwd": "/tmp/example",
        "thread_name": "s1",
        "timeout": 5
      }
    }
  ]
}
```

At the top level, use only `name` and `steps`. A step may use only `label`, `source`, `event`, `input`, `raw_input`, `process_timeout`, `expect`, and `envelope`. Use exactly one of `input` or `raw_input`; `raw_input` is a JSON string containing the literal stdin bytes for malformed-input cases.

Within `expect`, use only `exit_code`, `timed_out`, and `stdout`. Omitting `exit_code` skips that assertion. Within `envelope`, use only `event_name`, `source`, `cwd`, `thread_name`, and `timeout`. The client sets `timeout` to 5 for telemetry events and 7200 for `PermissionRequest`.

Envelope expectations are positional. A step with no `envelope` contributes no expected entry, although `drive` still runs it. Omit the block only when the step is expected to send nothing; otherwise later expectations shift and comparison fails. If a new scenario needs special server behavior, add an explicit case to `run-all.sh` so its decision, delay, no-reply mode, and lifetime are reproducible.
