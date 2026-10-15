#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-media.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -parse-as-library -o "$test_dir/checks" \
  'The Notch/Surfaces/System/NowPlaying/AdapterPayload.swift' \
  'The Notch/Surfaces/System/NowPlaying/NowPlayingStatus.swift' \
  'The Notch/Surfaces/System/NowPlaying/LyricsProvider.swift' \
  tools/media-tests/MediaTests.swift
"$test_dir/checks"
