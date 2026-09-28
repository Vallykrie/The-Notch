#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-sessions.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -default-isolation MainActor -parse-as-library -o "$test_dir/checks" \
  'The Notch/AgentBridge/AgentSessionStore.swift' \
  'The Notch/AgentBridge/AgentKind.swift' \
  'The Notch/AgentBridge/HookEvent.swift' \
  'The Notch/AgentBridge/AgentTool.swift' \
  'The Notch/AgentBridge/ApprovalQuestion.swift' \
  'The Notch/AgentBridge/TranscriptUsageReader.swift' \
  'The Notch/AgentBridge/CodexSessionReader.swift' \
  'The Notch/Surfaces/Agents/SessionStatus+Presentation.swift' \
  'The Notch/Surfaces/System/NowPlaying/NowPlayingStatus.swift' \
  'The Notch/Core/Theme.swift' \
  'The Notch/Core/Typography.swift' \
  'The Notch/Core/PixelGlyph.swift' \
  'The Notch/Core/NotchState.swift' \
  'The Notch/Core/NotchSettings.swift' \
  'The Notch/Core/SoundEffects.swift' \
  tools/session-tests/SessionTests.swift
"$test_dir/checks"
