#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-trading.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -parse-as-library -o "$test_dir/checks" \
  'The Notch/Trading/'*.swift 'The Notch/Core/LiveActivityLayout.swift' tools/trading-tests/TradingTests.swift
"$test_dir/checks"
