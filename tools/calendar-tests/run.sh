#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-calendar.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -parse-as-library -o "$test_dir/checks" \
  'The Notch/Calendar/CalendarModel.swift' tools/calendar-tests/CalendarTests.swift
"$test_dir/checks"
