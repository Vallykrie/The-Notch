import AppKit
import Darwin
import Foundation

/// Where an agent is running right now, if anywhere.
nonisolated struct AgentPresence: Equatable, Sendable {
    /// The app to bring forward for it: the agent's own app, or the terminal or IDE that hosts
    /// its CLI. `nil` when the process was found but nothing owning it could be.
    let applicationURL: URL?
}

/// Finds which coding agents are open on this Mac, by app and by CLI process.
///
/// Separate from `AgentCLIDetector`, which answers "is it installed and hooked up" and writes
/// hook config as it goes. This one only reads, cheaply enough to run every few seconds while
/// the empty agents panel is on screen, and never spawns `ps`.
nonisolated struct AgentPresenceScanner: Sendable {
    /// A GUI app as `NSWorkspace` reports it. Taken on the main actor and handed in, so the
    /// scan itself can run off it.
    struct RunningApp: Sendable {
        let bundleURL: URL
        let processID: pid_t
    }

    /// Interpreters a CLI agent may be launched through, where the agent's name is in the
    /// script argument rather than in the executable.
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    func scan(runningApps: [RunningApp]) -> [AgentCLI: AgentPresence] {
        var result: [AgentCLI: AgentPresence] = [:]

        for agent in AgentCLI.allCases {
            if let app = runningApps.first(where: { agent.appNames.contains($0.bundleURL.lastPathComponent) }) {
                result[agent] = AgentPresence(applicationURL: app.bundleURL)
            }
        }

        let pending = AgentCLI.allCases.filter { result[$0] == nil }
        guard !pending.isEmpty else { return result }

        let ancestry = ProcessAncestryStrategy()
        let ownPID = getpid()
        // Newest first, so a chip opens the terminal the user most recently started an agent in.
        for pid in Self.allProcessIDs().sorted(by: >) where pid != ownPID {
            let names = Self.commandNames(of: pid)
            guard !names.isEmpty,
                  let agent = pending.first(where: { result[$0] == nil && !Set($0.executables).isDisjoint(with: names) })
            else { continue }
            let owner = ancestry.resolve(fromProcessID: pid).owningApplicationBundleIdentifier
            let url = owner.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            result[agent] = AgentPresence(applicationURL: url)
            if pending.allSatisfy({ result[$0] != nil }) { break }
        }
        return result
    }

    /// Where the agent's own app is installed, for opening it when it is not running.
    static func installedApplicationURL(for agent: AgentCLI) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bases = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        for base in bases {
            for name in agent.appNames {
                let url = base.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: Processes

    private static func allProcessIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBufferPointer { pointer in
            proc_listallpids(pointer.baseAddress, Int32(capacity * MemoryLayout<pid_t>.stride))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count))).filter { $0 > 1 }
    }

    /// The names a process goes by: its executable, its `argv[0]`, and — when the executable
    /// is an interpreter — the script it was handed.
    ///
    /// `argv[0]` matters for Claude Code, whose binary resolves to a file named after its
    /// version number; only the name it was invoked as says "claude".
    private static func commandNames(of pid: pid_t) -> Set<String> {
        guard let arguments = ProcessInspector.commandLine(of: pid)?.arguments,
              let first = arguments.first else { return [] }
        let executable = ProcessInspector.basename(first)
        var names: Set<String> = [executable]
        if interpreters.contains(executable), arguments.count > 1 {
            names.insert(ProcessInspector.basename(arguments[1]))
        }
        return names
    }
}
