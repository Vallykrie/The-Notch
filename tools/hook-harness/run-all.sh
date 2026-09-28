#!/usr/bin/env bash

set -euo pipefail

if [[ ! -f tools/hook-harness/main.go || ! -f tools/notch-hook/main.go ]]; then
  echo "run-all.sh: run this script from the project root" >&2
  exit 2
fi

RUN_DIR="$(mktemp -d /tmp/notch-hook-harness.XXXXXX)"
HARNESS_PID=""
DRIVE_PID=""
WATCHDOG_PID=""

valid_pid() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

stop_pid() {
  local pid="$1"
  if valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
}

stop_drive_tree() {
  local pid="$1"
  local child
  if ! valid_pid "$pid"; then
    return
  fi
  while IFS= read -r child; do
    if valid_pid "$child"; then
      kill -TERM "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    fi
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  stop_pid "$pid"
}

cleanup_case() {
  if [[ -n "$WATCHDOG_PID" ]]; then
    stop_pid "$WATCHDOG_PID"
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
  fi
  if [[ -n "$DRIVE_PID" ]]; then
    stop_drive_tree "$DRIVE_PID"
    wait "$DRIVE_PID" 2>/dev/null || true
    DRIVE_PID=""
  fi
  if [[ -n "$HARNESS_PID" ]]; then
    stop_pid "$HARNESS_PID"
    wait "$HARNESS_PID" 2>/dev/null || true
    HARNESS_PID=""
  fi
}

cleanup() {
  cleanup_case
  rm -rf "$RUN_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

HOOK_BINARY="$RUN_DIR/notch-hook"
HARNESS_BINARY="$RUN_DIR/hook-harness"
export GOCACHE="$RUN_DIR/go-build-cache"

go build -C tools/notch-hook -o "$HOOK_BINARY" .
go build -C tools/hook-harness -o "$HARNESS_BINARY" .

SCENARIOS=(
  happy-path
  approval-allow
  approval-deny
  approval-timeout
  concurrent
  malformed
)
RESULTS=()
SCENARIO_TIMEOUT=15

run_scenario() {
  local scenario="$1"
  local case_dir="$RUN_DIR/$scenario"
  local socket_path="$case_dir/hook.sock"
  local report_path="$case_dir/report.jsonl"
  local serve_log="$case_dir/serve.log"
  local drive_log="$case_dir/drive.log"
  local timeout_marker="$case_dir/timed-out"
  local drive_status=0
  local server_ready=false
  local attempt
  local -a serve_args

  mkdir -p "$case_dir"
  serve_args=(serve --socket "$socket_path" --report "$report_path" --lifetime 20s)
  case "$scenario" in
    approval-allow)
      serve_args+=(--decision allow)
      ;;
    approval-deny)
      serve_args+=(--decision deny)
      ;;
    approval-timeout)
      serve_args+=(--no-reply --lifetime 1s)
      ;;
  esac

  "$HARNESS_BINARY" "${serve_args[@]}" >"$serve_log" 2>&1 &
  HARNESS_PID=$!

  for attempt in {1..100}; do
    if [[ -S "$socket_path" ]]; then
      server_ready=true
      break
    fi
    if ! kill -0 "$HARNESS_PID" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done

  if [[ "$server_ready" != true ]]; then
    echo "server did not become ready" >"$drive_log"
    cat "$serve_log" >>"$drive_log"
    cleanup_case
    return 1
  fi

  "$HARNESS_BINARY" drive \
    --scenario "$scenario" \
    --socket "$socket_path" \
    --report "$report_path" \
    --hook-binary "$HOOK_BINARY" >"$drive_log" 2>&1 &
  DRIVE_PID=$!

  (
    child_pids=()
    sleep "$SCENARIO_TIMEOUT"
    if kill -0 "$DRIVE_PID" 2>/dev/null; then
      : >"$timeout_marker"
      while IFS= read -r child; do
        if valid_pid "$child"; then
          child_pids+=("$child")
          kill -TERM "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
        fi
      done < <(pgrep -P "$DRIVE_PID" 2>/dev/null || true)
      stop_pid "$DRIVE_PID"
      sleep 1
      for child in "${child_pids[@]}"; do
        kill -KILL "-$child" 2>/dev/null || kill -KILL "$child" 2>/dev/null || true
      done
      if kill -0 "$DRIVE_PID" 2>/dev/null; then
        kill -KILL "$DRIVE_PID" 2>/dev/null || true
      fi
    fi
  ) &
  WATCHDOG_PID=$!

  if wait "$DRIVE_PID"; then
    drive_status=0
  else
    drive_status=$?
  fi
  DRIVE_PID=""

  stop_pid "$WATCHDOG_PID"
  wait "$WATCHDOG_PID" 2>/dev/null || true
  WATCHDOG_PID=""

  stop_pid "$HARNESS_PID"
  wait "$HARNESS_PID" 2>/dev/null || true
  HARNESS_PID=""

  if [[ -f "$timeout_marker" ]]; then
    echo "hard timeout after ${SCENARIO_TIMEOUT}s" >>"$drive_log"
    return 1
  fi
  return "$drive_status"
}

overall_status=0
for scenario in "${SCENARIOS[@]}"; do
  if run_scenario "$scenario"; then
    RESULTS+=("PASS")
  else
    RESULTS+=("FAIL")
    overall_status=1
    echo
    echo "--- $scenario output ---"
    cat "$RUN_DIR/$scenario/drive.log"
    if [[ -s "$RUN_DIR/$scenario/serve.log" ]]; then
      echo "--- $scenario server ---"
      cat "$RUN_DIR/$scenario/serve.log"
    fi
  fi
done

echo
printf '%-24s %s\n' "SCENARIO" "RESULT"
printf '%-24s %s\n' "------------------------" "------"
for index in "${!SCENARIOS[@]}"; do
  printf '%-24s %s\n' "${SCENARIOS[$index]}" "${RESULTS[$index]}"
done

exit "$overall_status"
