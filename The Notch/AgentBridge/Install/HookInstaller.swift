import Foundation

nonisolated enum HookInstallerError: Error, LocalizedError, Sendable {
    case binaryNotFound(URL)
    case malformedConfiguration(URL, String)
    case invalidHookStructure(URL, String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let url):
            "The notch-hook binary was not found at \(url.path)."
        case .malformedConfiguration(let url, let detail):
            "The agent configuration at \(url.path) is not valid JSON: \(detail)"
        case .invalidHookStructure(let url, let detail):
            "The agent configuration at \(url.path) has an unsupported hooks structure: \(detail)"
        }
    }
}

nonisolated struct HookInstaller: Sendable {
    /// The events we ask the agent to tell us about.
    ///
    /// `SubagentStart` joined the list when subagents became rows of their own: without it, a
    /// subagent only appeared once it ran its first tool, so a helper that spent twenty seconds
    /// reading before touching anything was invisible for all of it. `PostToolUseFailure`,
    /// `PreCompact` and `PostCompact` were already in `EventName`'s vocabulary and already
    /// carried state transitions — they were simply never subscribed to, so a compacting
    /// session showed as working and a failed tool call showed as still running.
    static let eventNames = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Notification", "Stop", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "PermissionRequest",
    ]

    let homeDirectory: URL
    let binarySourceURL: URL
    let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        binarySourceURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.binarySourceURL = binarySourceURL.standardizedFileURL
        self.environment = environment
    }

    var installedBinaryURL: URL {
        homeDirectory.appendingPathComponent(".the-notch/bin/notch-hook")
    }

    func configurationURL(for agent: AgentCLI) -> URL {
        agent.configurationURL(home: homeDirectory, environment: environment)
    }

    func install(for agent: AgentCLI) throws {
        try installBinary()
        try updateConfiguration(for: agent, operation: .install)
    }

    func install(for agents: some Sequence<AgentCLI>) throws {
        try installBinary()
        for agent in agents {
            try updateConfiguration(for: agent, operation: .install)
        }
    }

    func uninstall(for agent: AgentCLI) throws {
        try updateConfiguration(for: agent, operation: .uninstall)
    }

    func uninstall(for agents: some Sequence<AgentCLI>, removeBinary: Bool = true) throws {
        for agent in agents {
            try updateConfiguration(for: agent, operation: .uninstall)
        }
        if removeBinary, FileManager.default.fileExists(atPath: installedBinaryURL.path) {
            try FileManager.default.removeItem(at: installedBinaryURL)
        }
    }

    func installBinary() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: binarySourceURL.path) else {
            throw HookInstallerError.binaryNotFound(binarySourceURL)
        }

        let destination = installedBinaryURL
        if let existing = try? Data(contentsOf: destination),
           let bundled = try? Data(contentsOf: binarySourceURL), existing == bundled,
           fileManager.isExecutableFile(atPath: destination.path) { return }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".notch-hook.tmp.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        try fileManager.copyItem(at: binarySourceURL, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        try atomicallyReplace(destination: destination, with: temporary)
    }

    enum Operation {
        case install
        case uninstall
    }

    private func updateConfiguration(for agent: AgentCLI, operation: Operation) throws {
        if agent == .opencode {
            try updateOpenCodePlugin(install: operation == .install)
            return
        }
        let fileManager = FileManager.default
        let configURL = configurationURL(for: agent)
        let existed = fileManager.fileExists(atPath: configURL.path)

        if !existed, operation == .uninstall {
            return
        }

        let originalData = existed ? try Data(contentsOf: configURL) : Data("{}".utf8)
        let originalPermissions = existed
            ? try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions]
            : nil
        let root = try parseConfiguration(originalData, at: configURL)
        let mutation = try mutate(root: root, agent: agent, operation: operation, at: configURL)
        guard mutation.changed else { return }

        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if existed {
            try fileManager.copyItem(at: configURL, to: backupURL(for: configURL))
        }

        var writingOptions: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
        if originalData.contains(0x0A) {
            writingOptions.insert(.prettyPrinted)
        }
        var encoded = try JSONSerialization.data(withJSONObject: mutation.root, options: writingOptions)
        if originalData.last == 0x0A || writingOptions.contains(.prettyPrinted) {
            encoded.append(0x0A)
        }

        let temporary = directory.appendingPathComponent(".\(configURL.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try encoded.write(to: temporary, options: .withoutOverwriting)
        if let originalPermissions {
            try fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: temporary.path)
        }
        try atomicallyReplace(destination: configURL, with: temporary)
    }

    private func parseConfiguration(_ data: Data, at url: URL) throws -> [String: Any] {
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookInstallerError.malformedConfiguration(url, "the top-level value is not an object")
            }
            return root
        } catch let error as HookInstallerError {
            throw error
        } catch {
            throw HookInstallerError.malformedConfiguration(url, error.localizedDescription)
        }
    }

    private func mutate(
        root originalRoot: [String: Any],
        agent: AgentCLI,
        operation: Operation,
        at url: URL
    ) throws -> (root: [String: Any], changed: Bool) {
        if agent == .cursor || agent == .antigravity || agent == .kiro {
            return try mutateProvider(root: originalRoot, agent: agent, installing: operation == .install, at: url)
        }
        var root = originalRoot
        var hooks: [String: Any]
        if let existingHooks = root["hooks"] {
            guard let dictionary = existingHooks as? [String: Any] else {
                throw HookInstallerError.invalidHookStructure(url, "'hooks' is not an object")
            }
            hooks = dictionary
        } else {
            hooks = [:]
        }

        var changed = false
        // Remove our obsolete subscriptions too: Codex rejects Claude-only event keys.
        for eventName in Set(agent.events).union(Self.eventNames).sorted() {
            var groups: [[String: Any]]
            if let existingEvent = hooks[eventName] {
                guard let array = existingEvent as? [[String: Any]] else {
                    throw HookInstallerError.invalidHookStructure(url, "hooks.\(eventName) is not an array")
                }
                groups = array
            } else {
                groups = []
            }

            let result = mutateGroups(groups, eventName: eventName, agent: agent, operation: agent.events.contains(eventName) ? operation : .uninstall)
            if result.changed {
                changed = true
                if result.groups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = result.groups
                }
            }
        }

        if changed {
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
        }
        return (root, changed)
    }

    private func mutateGroups(
        _ originalGroups: [[String: Any]],
        eventName: String,
        agent: AgentCLI,
        operation: Operation
    ) -> (groups: [[String: Any]], changed: Bool) {
        var groups: [[String: Any]] = []
        var installed = false
        var changed = false
        let replacement = commandHook(eventName: eventName, agent: agent)

        for originalGroup in originalGroups {
            var group = originalGroup
            guard let originalCommands = group["hooks"] as? [[String: Any]] else {
                groups.append(group)
                continue
            }

            var commands: [[String: Any]] = []
            for command in originalCommands {
                guard isTheNotchHook(command, agent: agent) else {
                    commands.append(command)
                    continue
                }

                if operation == .uninstall {
                    changed = true
                } else if !installed {
                    commands.append(replacement)
                    installed = true
                    if !NSDictionary(dictionary: command).isEqual(to: replacement) {
                        changed = true
                    }
                } else {
                    changed = true
                }
            }

            if !commands.isEmpty {
                group["hooks"] = commands
                groups.append(group)
            }
        }

        if operation == .install, !installed {
            groups.append(["matcher": "", "hooks": [replacement]])
            changed = true
        }
        return (groups, changed)
    }

    /// Wrapped in `sh` with a trailing `exit 0` so the hook can never fail the user's agent.
    ///
    /// A bare `'<path>' --source claude` exits non-zero whenever the binary is missing, not yet
    /// installed, or crashing — and the agent treats that as a failed hook. The Notch is an
    /// ambient status app; it has no business making someone's Claude or Codex session error
    /// because our helper is broken. The `[ -x ... ]` test also covers the window between the
    /// config being written and the binary landing.
    private func commandHook(eventName: String, agent: AgentCLI) -> [String: Any] {
        return [
            "type": "command",
            "command": hookCommand(agent: agent, event: eventName),
            "timeout": agent == .gemini ? 5000 : (eventName == "PermissionRequest" ? 7200 : 5),
        ]
    }

    func hookCommand(agent: AgentCLI, event: String) -> String {
        let path = Self.shellQuote(installedBinaryURL.path)
        let command = "[ -x \(path) ] && \(path) --source \(agent.rawValue) --event \(Self.shellQuote(event)); exit 0"
        return "/bin/sh -c " + Self.shellQuote(command)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Matches on the binary name anywhere in the command rather than parsing the leading
    /// executable, because the command is now `/bin/sh -c '…'`. This also still recognises the
    /// older bare form, so upgrading replaces our own entry instead of appending a duplicate.
    private func isTheNotchHook(_ hook: [String: Any], agent: AgentCLI) -> Bool {
        guard let command = hook["command"] as? String,
              commandContainsSource(command, agent: agent)
        else { return false }
        return command.contains("notch-hook")
    }

    /// Whether this command runs *our* hook for *this* agent.
    ///
    /// The value after `--source` is compared with shell punctuation stripped, and that detail
    /// is the whole reason this function is worth a comment. The installed command is
    /// `/bin/sh -c '… --source claude; exit 0'`, so splitting on whitespace yields `claude;`
    /// — which never equalled `claude`, so the installer never recognised its own entry. It
    /// appended a fresh group on every single launch instead of replacing the one already
    /// there: the user's `settings.json` was found carrying forty-four copies of this hook per
    /// event, each of which spawns a process every time their agent does anything.
    ///
    /// With the comparison fixed, the existing dedupe in `mutateGroups` collapses the pile on
    /// the next install — the first match is replaced and every later one is dropped.
    private func commandContainsSource(_ command: String, agent: AgentCLI) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let sourceIndex = words.firstIndex(of: "--source"),
              words.indices.contains(sourceIndex + 1) else {
            return false
        }
        let source = words[sourceIndex + 1].trimmingCharacters(
            in: CharacterSet(charactersIn: ";&|'\"`)")
        )
        return source == agent.rawValue
    }

    private func commandExecutable(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        if first == "'" || first == "\"" {
            guard let closing = trimmed.dropFirst().firstIndex(of: first) else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
        }
        return trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private func backupURL(for configURL: URL) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return URL(fileURLWithPath: "\(configURL.path).the-notch-backup.\(formatter.string(from: Date()))")
    }

    private func atomicallyReplace(destination: URL, with temporary: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
