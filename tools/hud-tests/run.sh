#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-hud.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -parse-as-library -o "$test_dir/checks" \
  'The Notch/Surfaces/System/HUD/AccessibilityGrant.swift' tools/hud-tests/HUDTests.swift
"$test_dir/checks"
