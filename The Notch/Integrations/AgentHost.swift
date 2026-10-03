import AppKit
import Foundation

/// The app a session is running in — Terminal, iTerm, VS Code, the Claude desktop app — and
/// enough about the agent's own process to jump back to its exact tab where the terminal
/// allows it.
nonisolated struct AgentHost: Equatable, Sendable {
    let bundleIdentifier: String
    /// What the row calls it: the app's own display name, shortened where it is long.
    let name: String
    /// The agent's process, not the hook's: the hook has exited by the time anyone clicks.
    let agentProcessID: pid_t?
    let tty: String?
    let termProgram: String?
    let termSessionID: String?
    let iTermSessionID: String?
}

/// Works out an `AgentHost` from the process that delivered a hook event.
///
/// Nothing in the hook protocol says where the agent is running, and most agents would not
/// know if asked. The process tree does: the hook is a child of the agent, which is a child of
/// a shell, which belongs to a terminal or an IDE. So the server reads its peer's pid off the
/// socket and walks up from there — no change to `notch-hook` or to any agent's config.
nonisolated enum AgentHostResolver {
    /// Processes between the hook and the agent that are plumbing rather than the agent.
    private static let intermediaries: Set<String> = [
        "notch-hook", "sh", "bash", "zsh", "fish", "dash", "env", "login",
    ]

    private static let environmentKeys: Set<String> = [
        "TERM_PROGRAM", "TERM_SESSION_ID", "ITERM_SESSION_ID", "__CFBundleIdentifier",
    ]

    static func resolve(hookProcessID: pid_t) -> AgentHost? {
        let ancestry = ProcessAncestryStrategy().resolve(fromProcessID: hookProcessID)
        let processes = ancestry.processes
        let agentIndex = processes.indices.dropFirst().first { index in
            guard let path = processes[index].executablePath else { return false }
            return !intermediaries.contains(ProcessInspector.basename(path))
        }
        let agent = agentIndex.map { processes[$0] }
        // Only what is *above* the agent can host it. Some agents ship as an app bundle
        // themselves — Claude Code's binary lives in a `claude.app` — and would otherwise be
        // reported as running inside themselves.
        let above = agentIndex.map { processes[($0 + 1)...] } ?? processes.dropFirst()
        let treeOwner = above.lazy.compactMap(\.bundleIdentifier)
            .first(where: ProcessAncestryStrategy.isKnownTerminalOrIDE)
            ?? above.lazy.compactMap(\.bundleIdentifier).first
        let commandLine = agent.flatMap {
            ProcessInspector.commandLine(of: $0.processID, environmentKeys: environmentKeys)
        }
        let environment = commandLine?.environment ?? [:]

        // The process tree first, because it survives `tmux` and `ssh`-less nesting that leave
        // the environment pointing at whichever terminal started the multiplexer. The
        // environment covers the case the tree cannot: a multiplexer server reparented to
        // launchd, whose clients' terminal is no longer an ancestor at all.
        guard let bundleIdentifier = treeOwner ?? environment["__CFBundleIdentifier"],
            bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }

        return AgentHost(
            bundleIdentifier: bundleIdentifier,
            name: displayName(for: bundleIdentifier),
            agentProcessID: agent?.processID,
            tty: agent.flatMap { ProcessInspector.ttyPath(of: $0.processID) },
            termProgram: environment["TERM_PROGRAM"],
            termSessionID: environment["TERM_SESSION_ID"],
            iTermSessionID: environment["ITERM_SESSION_ID"]
        )
    }

    /// The host of a Codex session known only from its session file, from the client that
    /// wrote it. The desktop app is whichever of Codex's apps is running — it ships both on its
    /// own and inside ChatGPT. A CLI session's terminal cannot be known this way, so it has none.
    @MainActor
    static func codexHost(originator: String) -> AgentHost? {
        let lower = originator.lowercased()
        let bundleIdentifier: String?
        if lower.contains("desktop") {
            bundleIdentifier = NSWorkspace.shared.runningApplications.first { app in
                app.bundleURL.map { AgentCLI.codex.appNames.contains($0.lastPathComponent) } ?? false
            }?.bundleIdentifier
        } else if lower.contains("vscode") {
            bundleIdentifier = "com.microsoft.VSCode"
        } else {
            bundleIdentifier = nil
        }
        guard let bundleIdentifier else { return nil }
        return AgentHost(
            bundleIdentifier: bundleIdentifier,
            name: displayName(for: bundleIdentifier),
            agentProcessID: nil,
            tty: nil,
            termProgram: nil,
            termSessionID: nil,
            iTermSessionID: nil
        )
    }

    /// Short names for the apps whose own names would crowd a row.
    private static let shortNames: [String: String] = [
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.googlecode.iterm2": "iTerm",
        "com.anthropic.claudefordesktop": "Claude app",
        "com.openai.chat": "ChatGPT app",
        "dev.warp.Warp-Stable": "Warp",
    ]

    private static func displayName(for bundleIdentifier: String) -> String {
        if let short = shortNames[bundleIdentifier] { return short }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
