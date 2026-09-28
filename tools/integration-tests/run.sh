#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/notch-integration.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -o "$test_dir/checks" \
  'The Notch/AgentBridge/Install/AgentProvider.swift' \
  'The Notch/AgentBridge/Install/HookInstaller.swift' \
  'The Notch/AgentBridge/Install/ProviderHookInstaller.swift' \
  'The Notch/AgentBridge/Install/AgentCLIDetector.swift' \
  'The Notch/AgentBridge/HookEvent.swift' \
  'The Notch/AgentBridge/AgentTool.swift' \
  'The Notch/AgentBridge/ApprovalQuestion.swift' \
  'The Notch/AgentBridge/CodexSessionReader.swift' \
  tools/integration-tests/IntegrationTests.swift
"$test_dir/checks" "$@" --plugin-output "$test_dir/plugin.mjs"
node --experimental-vm-modules tools/integration-tests/opencode.test.mjs "$test_dir/plugin.mjs"
