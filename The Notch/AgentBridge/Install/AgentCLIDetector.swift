import Foundation

nonisolated enum AgentHookStatus: String, Sendable {
    case notHooked
    case current
    case stale
    case currentAndStale
    case unreadable
}

nonisolated struct AgentCLIStatus: Sendable {
    let agent: AgentCLI
    let configurationDirectoryPresent: Bool
    let executableURL: URL?
    let hookStatus: AgentHookStatus
    var applicationPresent: Bool = false

    var isInstalled: Bool {
        configurationDirectoryPresent || executableURL != nil || applicationPresent
    }

    var isHooked: Bool {
        hookStatus == .current || hookStatus == .currentAndStale
    }

    var hasStaleBinaryPath: Bool {
        hookStatus == .stale || hookStatus == .currentAndStale
    }
}

nonisolated struct AgentCLIDetector: Sendable {
    let homeDirectory: URL
    let pathEnvironment: String
    let environment: [String: String]
    let applicationsDirectories: [URL]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnvironment: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationsDirectories: [URL]? = nil
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.pathEnvironment = pathEnvironment
        self.environment = environment
        self.applicationsDirectories = applicationsDirectories ?? [URL(fileURLWithPath: "/Applications"), homeDirectory.appendingPathComponent("Applications")]
    }

    func detect() -> [AgentCLIStatus] {
        AgentCLI.allCases.map { agent in
            AgentCLIStatus(
                agent: agent,
                configurationDirectoryPresent: configurationDirectoryExists(for: agent),
                executableURL: agent.executables.compactMap { executableURL(named: $0) }.first,
                hookStatus: detectHookStatus(for: agent),
                applicationPresent: applicationsDirectories.contains { base in
                    agent.appNames.contains { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) }
                }
            )
        }
    }

    private func configurationDirectoryExists(for agent: AgentCLI) -> Bool {
        agent.detectionDirectories.contains { FileManager.default.fileExists(atPath: homeDirectory.appendingPathComponent($0).path) }
            || FileManager.default.fileExists(atPath: agent.configurationURL(home: homeDirectory, environment: environment).path)
    }

    private func executableURL(named name: String) -> URL? {
        let common = [".local/bin", ".opencode/bin", ".cargo/bin", ".bun/bin"].map { homeDirectory.appendingPathComponent($0).path }
        for directory in pathEnvironment.split(separator: ":").map(String.init) + common + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let base = directory.isEmpty ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath) : URL(fileURLWithPath: String(directory))
            let candidate = base.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    private func detectHookStatus(for agent: AgentCLI) -> AgentHookStatus {
        let configURL = agent.configurationURL(home: homeDirectory, environment: environment)
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .notHooked }

        do {
            let data = try Data(contentsOf: configURL)
            if agent == .opencode {
                return String(decoding: data, as: UTF8.self).hasPrefix("// The Notch integration") ? .current : .notHooked
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unreadable
            }
            let commands = hookCommands(in: root)
            let expected = homeDirectory.appendingPathComponent(".the-notch/bin/notch-hook").standardizedFileURL.path
            var current = false
            var stale = false
            for command in commands where commandContainsSource(command, agent: agent) {
                guard command.contains("notch-hook") else { continue }
                var unwrapped = command
                for _ in 0..<3 { unwrapped = unwrapped.replacingOccurrences(of: "'\"'\"'", with: "'") }
                if unwrapped.contains(expected) {
                    current = true
                } else {
                    stale = true
                }
            }
            return switch (current, stale) {
            case (true, true): .currentAndStale
            case (true, false): .current
            case (false, true): .stale
            case (false, false): .notHooked
            }
        } catch {
            return .unreadable
        }
    }

    private func hookCommands(in value: Any?) -> [String] {
        if let dictionary = value as? [String: Any] {
            var commands = dictionary.values.flatMap { hookCommands(in: $0) }
            if let command = dictionary["command"] as? String {
                commands.append(command)
            }
            return commands
        }
        if let array = value as? [Any] {
            return array.flatMap { hookCommands(in: $0) }
        }
        return []
    }

    private func commandContainsSource(_ command: String, agent: AgentCLI) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let sourceIndex = words.firstIndex(of: "--source"), words.indices.contains(sourceIndex + 1) else {
            return false
        }
        return words[sourceIndex + 1].trimmingCharacters(in: CharacterSet(charactersIn: ";&|\"'`)")) == agent.rawValue
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
}
