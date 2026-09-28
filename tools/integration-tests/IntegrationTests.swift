import Foundation

@main
struct IntegrationTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("notch-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        // Shell metacharacters in home paths must survive installation without executing.
        let home = root.appendingPathComponent("user's $money `home`")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("notch-hook")
        try Data("#!/bin/sh\ncat >/dev/null\nexit 0\n".utf8).write(to: binary)
        let installer = HookInstaller(homeDirectory: home, binarySourceURL: binary, environment: [:])
        for provider in AgentCLI.allCases {
            let config = installer.configurationURL(for: provider)
            try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            if provider != .opencode {
                let original: [String: Any] = provider == .antigravity
                    ? ["other-integration": ["Stop": [["command": "keep-me"]]]]
                    : ["keep_me": ["nested": true]]
                try JSONSerialization.data(withJSONObject: original).write(to: config)
            }
            try installer.install(for: provider)
            let first = try Data(contentsOf: config)
            try installer.install(for: provider)
            require(try Data(contentsOf: config) == first, "\(provider): install must be idempotent")
            let status = AgentCLIDetector(homeDirectory: home, pathEnvironment: "", environment: [:], applicationsDirectories: []).detect().first { $0.agent == provider }!
            require(status.isHooked, "\(provider): wrapped hooks must be detected")
            if provider != .opencode {
                let json = try JSONSerialization.jsonObject(with: first) as! [String: Any]
                require(json[provider == .antigravity ? "other-integration" : "keep_me"] != nil, "\(provider): removed another setting")
            }
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = ["-c", installer.hookCommand(agent: provider, event: provider.events.first ?? "Stop")]
            shell.standardInput = FileHandle.nullDevice
            try shell.run(); shell.waitUntilExit()
            require(shell.terminationStatus == 0, "unsafe shell quoting for \(provider)")
            try installer.uninstall(for: provider)
            if provider != .opencode {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
                require(json[provider == .antigravity ? "other-integration" : "keep_me"] != nil, "\(provider): uninstall removed unrelated config")
            }
        }
        let codex = installer.configurationURL(for: .codex)
        let old: [String: Any] = ["hooks": ["Notification": [["hooks": [["type": "command", "command": "notch-hook --source codex"]]]], "Stop": [["hooks": [["type": "command", "command": "other-program"]]]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: codex)
        try installer.install(for: .codex)
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: codex)) as! [String: Any]
        let hooks = migrated["hooks"] as! [String: Any]
        require(hooks["Notification"] == nil, "Codex must remove obsolete Claude-only subscriptions")
        require(String(decoding: try Data(contentsOf: codex), as: UTF8.self).contains("other-program"), "migration removed foreign hook")
        let malformed = Data("{broken".utf8)
        try malformed.write(to: codex)
        do { try installer.install(for: .codex); fatalError("must reject malformed config") } catch {}
        require(try Data(contentsOf: codex) == malformed, "malformed config overwritten")
        let custom = root.appendingPathComponent("custom-codex")
        let overridden = HookInstaller(homeDirectory: home, binarySourceURL: binary, environment: ["CODEX_HOME": custom.path])
        try overridden.install(for: .codex)
        require(fm.fileExists(atPath: custom.appendingPathComponent("hooks.json").path), "CODEX_HOME ignored")
        try await testCodexReader(home: home)
        if CommandLine.arguments.contains("--probe-local") {
            let reader = CodexSessionReader()
            let events = await reader.poll()
            print("Live Codex sessions observed: \(events.count)")
        }
        if let i = CommandLine.arguments.firstIndex(of: "--plugin-output"), CommandLine.arguments.indices.contains(i + 1) {
            try Data(HookInstaller.openCodePlugin.utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        print("PASS: seven provider installers, preservation, idempotency, shell escaping, migration, overrides, Codex lifecycle/tailing")
    }

    static func testCodexReader(home: URL) async throws {
        let dir = home.appendingPathComponent(".codex/sessions/2026/09/22")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("fixture.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        func record(_ type: String, _ payload: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: now), "payload": payload])
            data.append(10); return data
        }
        var content = try record("session_meta", ["id": "desktop-session", "cwd": "/project", "originator": "Codex Desktop", "source": "vscode"])
        content.append(try record("event_msg", ["type": "task_started"]))
        try content.write(to: url)
        let reader = CodexSessionReader(home: home, environment: [:])
        let first = await reader.poll(now: now)
        require(first.count == 1 && first[0].request.threadName == "desktop-session", "desktop session not discovered")
        let duplicate = await reader.poll(now: now)
        require(duplicate.isEmpty, "unchanged file replayed")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let tool = try record("response_item", ["type": "function_call", "name": "exec_command"])
        try handle.write(contentsOf: tool.dropLast())
        let partial = await reader.poll(now: now)
        require(partial.isEmpty, "partial line was parsed")
        try handle.write(contentsOf: Data([10]))
        let completed = await reader.poll(now: now)
        require(completed.count == 1 && completed[0].request.eventName == .preToolUse, "partial tool event lost")
        try handle.write(contentsOf: record("event_msg", ["type": "task_complete"]))
        try handle.close()
        let stop = await reader.poll(now: now)
        require(stop.count == 1 && stop[0].request.eventName == .stop, "completion missed")
        let fresh = CodexSessionReader(home: home, environment: [:])
        let historical = await fresh.poll(now: now)
        require(historical.isEmpty, "completed history resurrected on launch")
    }
}
